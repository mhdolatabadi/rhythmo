FROM python:3.12-slim
RUN pip install --no-cache-dir faster-whisper==1.2.1
# Bake the default model in, so the server never has to reach Hugging Face.
ARG WHISPER_MODEL=large-v3-turbo
RUN python -c "import sys; from faster_whisper import download_model; download_model(sys.argv[1], output_dir='/opt/whisper/' + sys.argv[1])" "$WHISPER_MODEL" \
    && test -f "/opt/whisper/$WHISPER_MODEL/model.bin"
RUN useradd --uid 10001 --create-home transcriber && mkdir /models && chown transcriber /models
COPY service.py /app/service.py
USER transcriber
EXPOSE 8090
ENTRYPOINT ["python", "/app/service.py"]
