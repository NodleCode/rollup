FROM node:20

WORKDIR /usr/src/app

COPY . .

RUN yarn install

RUN yarn build

EXPOSE 8080

CMD ["yarn", "start"]