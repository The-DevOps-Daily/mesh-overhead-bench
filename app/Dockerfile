FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /hop .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /hop /hop
USER 65532
ENTRYPOINT ["/hop"]
