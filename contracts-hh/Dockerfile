FROM node:latest

WORKDIR /app

COPY . .

# prebuild all dependencies - while a nice performance boost
# this means we need to rebuild this container when we add
# new dependencies / node modules via `docker compose build`
RUN yarn

# every time this container run, it will compile and deploy the
# later contract
ENTRYPOINT yarn compile && yarn deploy --network dockerComposeNode