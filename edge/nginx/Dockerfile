FROM node:24-alpine@sha256:a0b9bf06e4e6193cf7a0f58816cc935ff8c2a908f81e6f1a95432d679c54fbfd AS build
WORKDIR /workspace/llm-council-ui
COPY llm-council-ui/package*.json ./
RUN npm ci
COPY llm-council-ui/ ./
RUN npm run build

FROM nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
COPY llm-council-infra/edge/nginx/conf.d/site.http.conf.template /etc/nginx/templates/default.conf.template
COPY llm-council-infra/edge/nginx/docker-entrypoint.d/40-runtime-config.sh /docker-entrypoint.d/40-runtime-config.sh
COPY --from=build /workspace/llm-council-ui/dist/ai-orchestrator-ui/browser/ /usr/share/nginx/html/
RUN chmod +x /docker-entrypoint.d/40-runtime-config.sh
