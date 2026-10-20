// Package storage keeps audio in a private MinIO bucket and hands out
// short-lived presigned URLs for it.
package storage

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// region is fixed so presigning never has to ask MinIO for the bucket location.
const region = "us-east-1"

type Config struct {
	// Endpoint is the internal host:port the API uses, for example minio:9000.
	Endpoint string
	// PublicURL is the origin clients reach MinIO through, for example
	// https://music.example.com. URLs are signed for this host.
	PublicURL string
	AccessKey string
	SecretKey string
	Bucket    string
	URLTTL    time.Duration
	// UploadTTL is how long a client has to start an upload.
	UploadTTL time.Duration
}

type Storage struct {
	internal  *minio.Client
	public    *minio.Client
	bucket    string
	ttl       time.Duration
	uploadTTL time.Duration
	now       func() time.Time
}

// ErrObjectMissing means nothing has been uploaded at the key yet.
var ErrObjectMissing = errors.New("object not found")

// Upload is a presigned POST form: the client sends Fields plus the file
// (as the last form field, named "file") to URL.
type Upload struct {
	URL       string
	Fields    map[string]string
	ExpiresAt time.Time
}

func New(config Config) (*Storage, error) {
	if config.Bucket == "" || config.AccessKey == "" || config.SecretKey == "" {
		return nil, errors.New("storage bucket and credentials are required")
	}
	if config.URLTTL <= 0 || config.URLTTL > 7*24*time.Hour {
		return nil, errors.New("storage URL lifetime must be between 0 and 7 days")
	}
	if config.UploadTTL == 0 {
		config.UploadTTL = time.Hour
	}
	creds := credentials.NewStaticV4(config.AccessKey, config.SecretKey, "")

	internal, err := minio.New(config.Endpoint, &minio.Options{Creds: creds, Region: region})
	if err != nil {
		return nil, fmt.Errorf("internal endpoint: %w", err)
	}
	publicURL, err := url.Parse(config.PublicURL)
	if err != nil || publicURL.Host == "" || (publicURL.Scheme != "https" && publicURL.Scheme != "http") {
		return nil, fmt.Errorf("public URL %q must be an http(s) origin", config.PublicURL)
	}
	public, err := minio.New(publicURL.Host, &minio.Options{
		Creds:  creds,
		Secure: publicURL.Scheme == "https",
		Region: region,
	})
	if err != nil {
		return nil, fmt.Errorf("public endpoint: %w", err)
	}
	return &Storage{
		internal: internal, public: public, bucket: config.Bucket,
		ttl: config.URLTTL, uploadTTL: config.UploadTTL, now: time.Now,
	}, nil
}

// EnsureBucket creates the bucket if needed. New buckets in MinIO are private;
// no anonymous policy is ever attached.
func (s *Storage) EnsureBucket(ctx context.Context) error {
	exists, err := s.internal.BucketExists(ctx, s.bucket)
	if err != nil {
		return err
	}
	if exists {
		return nil
	}
	return s.internal.MakeBucket(ctx, s.bucket, minio.MakeBucketOptions{Region: region})
}

// PresignGet returns a URL that allows reading key until the returned time.
func (s *Storage) PresignGet(ctx context.Context, key string) (string, time.Time, error) {
	expiresAt := s.now().Add(s.ttl)
	signed, err := s.public.PresignedGetObject(ctx, s.bucket, key, s.ttl, url.Values{})
	if err != nil {
		return "", time.Time{}, err
	}
	return signed.String(), expiresAt, nil
}

// PresignDownload is PresignGet for saving the object as a file: storage
// answers with the given Content-Disposition and Content-Type, which are part
// of the signature, and tells caches not to reuse the response.
func (s *Storage) PresignDownload(ctx context.Context, key, disposition, contentType string) (string, time.Time, error) {
	expiresAt := s.now().Add(s.ttl)
	params := url.Values{
		"response-content-disposition": {disposition},
		"response-content-type":        {contentType},
		"response-cache-control":       {"private, no-cache"},
	}
	signed, err := s.public.PresignedGetObject(ctx, s.bucket, key, s.ttl, params)
	if err != nil {
		return "", time.Time{}, err
	}
	return signed.String(), expiresAt, nil
}

// PresignUpload returns a POST policy that MinIO itself enforces: only this
// key, only this content type, and exactly sizeBytes bytes.
func (s *Storage) PresignUpload(ctx context.Context, key, contentType string, sizeBytes int64) (Upload, error) {
	expiresAt := s.now().Add(s.uploadTTL)
	policy := minio.NewPostPolicy()
	for _, err := range []error{
		policy.SetBucket(s.bucket),
		policy.SetKey(key),
		policy.SetContentType(contentType),
		policy.SetContentLengthRange(sizeBytes, sizeBytes),
		policy.SetExpires(expiresAt.UTC()),
	} {
		if err != nil {
			return Upload{}, err
		}
	}
	postURL, fields, err := s.public.PresignedPostPolicy(ctx, policy)
	if err != nil {
		return Upload{}, err
	}
	return Upload{URL: postURL.String(), Fields: fields, ExpiresAt: expiresAt}, nil
}

// Size returns the stored object's size.
func (s *Storage) Size(ctx context.Context, key string) (int64, error) {
	info, err := s.internal.StatObject(ctx, s.bucket, key, minio.StatObjectOptions{})
	if minio.ToErrorResponse(err).Code == "NoSuchKey" {
		return 0, ErrObjectMissing
	}
	if err != nil {
		return 0, err
	}
	return info.Size, nil
}

// Head returns up to n bytes from the start of the object.
func (s *Storage) Head(ctx context.Context, key string, n int64) ([]byte, error) {
	options := minio.GetObjectOptions{}
	if err := options.SetRange(0, n-1); err != nil {
		return nil, err
	}
	object, err := s.internal.GetObject(ctx, s.bucket, key, options)
	if err != nil {
		return nil, err
	}
	defer object.Close()
	return io.ReadAll(io.LimitReader(object, n))
}

// Remove deletes the object; a missing object is not an error.
func (s *Storage) Remove(ctx context.Context, key string) error {
	return s.internal.RemoveObject(ctx, s.bucket, key, minio.RemoveObjectOptions{})
}

// Put streams exactly size bytes from r into key. The API uses it for audio it
// fetches itself, such as bot imports; clients upload through PresignUpload.
func (s *Storage) Put(ctx context.Context, key string, r io.Reader, size int64, contentType string) error {
	_, err := s.internal.PutObject(ctx, s.bucket, key, r, size, minio.PutObjectOptions{ContentType: contentType})
	return err
}

// Open streams the object at key.
func (s *Storage) Open(ctx context.Context, key string) (io.ReadCloser, error) {
	return s.internal.GetObject(ctx, s.bucket, key, minio.GetObjectOptions{})
}

// Copy duplicates an object inside the bucket without moving it through the
// API, for example when someone saves a shared playlist to their account.
func (s *Storage) Copy(ctx context.Context, srcKey, dstKey string) error {
	_, err := s.internal.CopyObject(ctx,
		minio.CopyDestOptions{Bucket: s.bucket, Object: dstKey},
		minio.CopySrcOptions{Bucket: s.bucket, Object: srcKey})
	return err
}

// RemovePrefix deletes every object whose key starts with prefix and returns
// how many it removed; an empty prefix is not an error. The prefix must be a
// non-empty folder such as "users/<id>/", so a bad caller can never empty the
// whole bucket.
func (s *Storage) RemovePrefix(ctx context.Context, prefix string) (int, error) {
	if !validPrefix(prefix) {
		return 0, fmt.Errorf("refusing to remove objects under %q", prefix)
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	listed := s.internal.ListObjects(ctx, s.bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true})
	keys := make(chan minio.ObjectInfo)
	type listing struct {
		count int
		err   error
	}
	// Buffered, so the lister never blocks on it; it is sent before keys closes.
	done := make(chan listing, 1)
	go func() {
		defer close(keys)
		count := 0
		for object := range listed {
			if object.Err != nil {
				done <- listing{count, object.Err}
				return
			}
			select {
			case keys <- object:
				count++
			case <-ctx.Done():
				done <- listing{count, ctx.Err()}
				return
			}
		}
		done <- listing{count, nil}
	}()
	var removeErr error
	for result := range s.internal.RemoveObjects(ctx, s.bucket, keys, minio.RemoveObjectsOptions{}) {
		if result.Err != nil && removeErr == nil {
			removeErr = fmt.Errorf("remove %s: %w", result.ObjectName, result.Err)
		}
	}
	listedKeys := <-done
	if listedKeys.err != nil {
		return 0, fmt.Errorf("list %s: %w", prefix, listedKeys.err)
	}
	if removeErr != nil {
		return 0, removeErr
	}
	return listedKeys.count, nil
}

func validPrefix(prefix string) bool {
	trimmed := strings.Trim(prefix, "/")
	return trimmed != "" && strings.HasSuffix(prefix, "/") && !strings.HasPrefix(prefix, "/") &&
		!strings.Contains(prefix, "//") && !strings.Contains(prefix, "..")
}

// ErrPublicBucket means the bucket has a policy that lets anyone read or
// write it without a signature. Audio must only ever be reachable through
// presigned URLs (#217).
var ErrPublicBucket = errors.New("the storage bucket allows anonymous access")

// CheckPrivate returns ErrPublicBucket when the bucket's policy grants
// anything to anonymous users. A bucket without a policy is private.
func (s *Storage) CheckPrivate(ctx context.Context) error {
	policy, err := s.internal.GetBucketPolicy(ctx, s.bucket)
	if err != nil {
		return fmt.Errorf("read bucket policy: %w", err)
	}
	public, err := allowsAnonymous(policy)
	if err != nil {
		return fmt.Errorf("parse bucket policy: %w", err)
	}
	if public {
		return ErrPublicBucket
	}
	return nil
}

// allowsAnonymous reports whether an S3 bucket policy has an Allow statement
// whose principal includes everyone ("*").
func allowsAnonymous(policy string) (bool, error) {
	if strings.TrimSpace(policy) == "" {
		return false, nil
	}
	var doc struct {
		Statement []struct {
			Effect    string          `json:"Effect"`
			Principal json.RawMessage `json:"Principal"`
		} `json:"Statement"`
	}
	if err := json.Unmarshal([]byte(policy), &doc); err != nil {
		return false, err
	}
	for _, statement := range doc.Statement {
		if !strings.EqualFold(statement.Effect, "Allow") {
			continue
		}
		if principalIsEveryone(statement.Principal) {
			return true, nil
		}
	}
	return false, nil
}

// principalIsEveryone accepts the forms a policy may use: "*", {"AWS": "*"}
// and {"AWS": ["…", "*"]}.
func principalIsEveryone(raw json.RawMessage) bool {
	var single string
	if json.Unmarshal(raw, &single) == nil {
		return single == "*"
	}
	var byKind map[string]json.RawMessage
	if json.Unmarshal(raw, &byKind) != nil {
		return false
	}
	for _, value := range byKind {
		if json.Unmarshal(value, &single) == nil && single == "*" {
			return true
		}
		var list []string
		if json.Unmarshal(value, &list) == nil && slices.Contains(list, "*") {
			return true
		}
	}
	return false
}

// ReadRange reads metadata without downloading intervening audio samples.
func (s *Storage) ReadRange(ctx context.Context, key string, offset, size int64) ([]byte, error) {
	if offset < 0 || size <= 0 || size > 16<<20 {
		return nil, errors.New("invalid metadata range")
	}
	options := minio.GetObjectOptions{}
	if err := options.SetRange(offset, offset+size-1); err != nil {
		return nil, err
	}
	object, err := s.internal.GetObject(ctx, s.bucket, key, options)
	if err != nil {
		return nil, err
	}
	defer object.Close()
	return io.ReadAll(io.LimitReader(object, size))
}
