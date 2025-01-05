## Use the official Bun base image
#FROM jarredsumner/bun:edge
#
## Set working directory
#WORKDIR /app
#
## Copy package.json, bun.lockb, and other app files
#COPY . .
#
## Install dependencies
#RUN bun install
#
## Expose the port your application runs on
#EXPOSE 3000
#
## Command to run your application
#CMD ["bun", "run", "dev"]

FROM jarredsumner/bun:edge

WORKDIR /app

# 먼저 package.json과 bun.lockb만 복사
COPY package.json bun.lockb ./

# 의존성 설치
RUN bun install

# 나머지 파일 복사
COPY . .

EXPOSE 3000

CMD ["bun", "run", "dev"]
