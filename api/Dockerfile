FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app

# Run as the same uid/gid as ERDDAP's Tomcat (1000) so it can write the
# reload flags in /erddapData/flag. Override with `docker run --user`.
USER 1000:1000
EXPOSE 8000
# No --proxy-headers: X-Forwarded-For is client-controlled. The real client IP comes
# from CLIENT_IP_HEADER (see app/main.py) and the public URL from PUBLIC_URL.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-proxy-headers"]
