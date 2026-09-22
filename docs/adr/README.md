<img src="https://cdn.prod.website-files.com/677c400686e724409a5a7409/6790ad949cf622dc8dcd9fe4_nextwork-logo-leather.svg" alt="NextWork" width="300" />

# Cross-Chain DEX Arbitrage Scanner

**Project Link:** [View Project](https://learn.nextwork.org/projects/7a9d23d3-0dee-473b-81bf-0f261b4675a8)

**Author:** Hamza Aziz  
**Email:** hamzaaziz5874@gmail.com

---

![Image](https://learn.nextwork.org/curious_white_noble_basil/uploads/7a9d23d3-0dee-473b-81bf-0f261b4675a8_9lfkzwu8)

## Project Vision: Cross-Chain DEX Arbitrage Scanner

### What this project builds and why

A Node.js application that queries the DexPaprika API for token prices across Ethereum, BSC, Polygon, and Arbitrum, compares them to find arbitrage opportunities, and ships inside a production-ready Docker container with a fully automated GitHub Actions pipeline.

## Setting Up the Project Environment

### Environment and project structure

Create the project folder and initialize npm.

Set up the source file structure for the scanner.

Create a .gitignore and initialize Git for version control.

![Image](https://learn.nextwork.org/curious_white_noble_basil/uploads/7a9d23d3-0dee-473b-81bf-0f261b4675a8_wj5azq7o)

### Purpose of .gitignore

A .gitignore file tells Git which files to leave out of version control. You want to exclude installed packages and any secret files.

## Fetching Real-Time Token Prices Across Blockchains

### Building the price fetcher

Define the token configuration with contract addresses for each chain.

Build functions to fetch prices from the DexPaprika API.

Test the price fetcher with live data.

![Image](https://learn.nextwork.org/curious_white_noble_basil/uploads/7a9d23d3-0dee-473b-81bf-0f261b4675a8_27b5r8br)

### Resilient API calls with Promise.allSettled

We use Promise.allSettled

When you query 11 different token/chain combinations, some might fail due to network issues or unsupported tokens. Promise.all would reject the entire batch if a single request fails.

Promise.allSettled gives you results for every request regardless of success or failure. Your scanner still produces useful output even if one or two chains are unreachable.

## Detecting Cross-Chain Arbitrage Opportunities

### Building the arbitrage detector

Create the arbitrage detection module that compares prices across chains.

Build the main entry point that orchestrates fetching, detecting, and displaying results.

Run the full scanner and verify it outputs live arbitrage opportunities.

![Image](https://learn.nextwork.org/curious_white_noble_basil/uploads/7a9d23d3-0dee-473b-81bf-0f261b4675a8_iwhjwa6f)

### How buy and sell chains are identified

The function takes the flat array of price points from your scanner and groups them by token symbol (WETH, USDC, USDT).

For each token, it scans all available chain prices to find the lowest (where you'd buy) and the highest (where you'd sell). The spread percentage tells you how much profit exists between those two chains.

## Containerizing the Scanner with Docker

### Containerization approach

Write a multi-stage Dockerfile optimized for production.

Create a .dockerignore to keep the build context lean.

Build and run the container locally to verify the scanner works inside Docker.

![Image](https://learn.nextwork.org/curious_white_noble_basil/uploads/7a9d23d3-0dee-473b-81bf-0f261b4675a8_4tdle13r)

### Multi-stage build pattern explained

Without multi-stage, your final image would include build tools, intermediate files, and anything else from the install process. Multi-stage lets you discard all of that. Only the runtime essentials make it into the production image, which means a smaller image size and a reduced attack surface.







## Automating Builds with GitHub Actions CI/CD

### Setting up the CI/CD pipeline

Push your project to a new GitHub repository and configure Docker Hub secrets.

Create a GitHub Actions workflow that tests and builds your scanner.

Verify the pipeline passes and your Docker image appears on Docker Hub.

### The two pipeline jobs and their roles

This workflow has two jobs that run sequentially:





test checks out your code, installs Node.js 22, runs npm install to install dependencies, and executes the scanner to confirm it runs without errors.



build-and-push only runs after test passes (needs: test). It logs into Docker Hub using your secrets, builds the Docker image with Buildx, and pushes it with two tags: latest and the commit SHA for version tracking.



The if: condition ensures the Docker image is only built on direct pushes to main. Pull requests trigger the test job only.

## Live Arbitrage Detection with Real-Time Streaming

![Image](https://learn.nextwork.org/curious_white_noble_basil/uploads/7a9d23d3-0dee-473b-81bf-0f261b4675a8_2x9wgdug)

### Streaming mode vs one-shot scan

You upgraded your scanner from a one-shot tool to a real-time monitoring system. Professional trading bots use this exact pattern. They maintain persistent connections to data feeds, keep in-memory state, and trigger actions when conditions are met.

The dual-mode Docker image means your single container can serve both use cases. Scheduled scans for periodic checks. Continuous streaming for active monitoring.

## Reflections and Key Takeaways

### Tools and concepts learned

In this project, I learned how to build a Node.js command-line application that queries the DexPaprika API to fetch real-time token prices across Ethereum, BSC, Polygon, and Arbitrum, then compares them to detect cross-chain arbitrage opportunities using spread percentage calculations. I used Promise.allSettled for resilient parallel API calls, applied separation of concerns by splitting logic into focused modules (config, scanner, arbitrage, index), and containerized the app with a multi-stage Docker build for lean production images. I then set up a GitHub Actions CI/CD pipeline that automatically tests and builds the Docker image on every push to main, using repository secrets for secure credential management. In the Secret Mission, I extended the scanner with Server-Sent Events for real-time price streaming and built a dual-mode Docker container that switches between one-shot scanning and live monitoring via environment variables.

### Time and challenges

1 hour

### Final reflections

Thanks

---

*Built with [NextWork](https://learn.nextwork.org) - [View this project](https://learn.nextwork.org/projects/7a9d23d3-0dee-473b-81bf-0f261b4675a8)*
