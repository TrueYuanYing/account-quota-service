FROM node:24-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY account_api.mjs account_store.mjs account_identity.mjs account_management.mjs account_model.mjs model_journal.mjs provider_registry.mjs provider_gateway.mjs capacity.mjs zpay_checkout.mjs zpay_protocol.mjs service.mjs ./
CMD ["node", "service.mjs"]
