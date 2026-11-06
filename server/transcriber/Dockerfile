FROM python:3.12-slim
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
# Fail the build, not every job, when the libraries cannot decode audio together.
RUN python -c "import wave; w = wave.open('/tmp/t.wav', 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(32000)); w.close(); from faster_whisper.audio import decode_audio; assert len(decode_audio('/tmp/t.wav')) == 16000" \
    && rm /tmp/t.wav
# Bake the default model in, so the server never has to reach Hugging Face.
ARG WHISPER_MODEL=large-v3-turbo
RUN python -c "import sys; from faster_whisper import download_model; download_model(sys.argv[1], output_dir='/opt/whisper/' + sys.argv[1])" "$WHISPER_MODEL" \
    && test -f "/opt/whisper/$WHISPER_MODEL/model.bin"
RUN useradd --uid 10001 --create-home transcriber && mkdir /models && chown transcriber /models
COPY service.py /app/service.py
USER transcriber
EXPOSE 8090
ENTRYPOINT ["python", "/app/service.py"]
