FROM golang:1.26-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 go build -o /writeload .

FROM scratch
COPY --from=builder /writeload /writeload
ENTRYPOINT ["/writeload"]
