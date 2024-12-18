# Use the official Bun base image
FROM jarredsumner/bun:edge

# Set working directory
WORKDIR /app

# Copy package.json, bun.lockb, and other app files
COPY . .

# Install dependencies
RUN bun install

# Expose the port your application runs on
EXPOSE 3000

# Command to run your application
CMD ["bun", "run", "dev"]
