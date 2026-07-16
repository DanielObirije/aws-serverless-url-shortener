#!/bin/bash
set -e  # Exit on any error

echo "📦 Installing dependencies..."
npm install

echo "🔍 Type checking..."
npm run type-check

echo "🚀 Building with esbuild..."
npm run build:zip

echo "✅ Build complete! lambda_function.zip created"