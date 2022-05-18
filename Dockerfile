FROM python:3-alpine

RUN pip install yq
RUN apk add jq
