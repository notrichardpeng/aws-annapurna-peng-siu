# Production-Ready LLM Deployment with Real-Time Monitoring

**Challenge**: Deploy an optimized language model with production-grade monitoring, logging, and performance tracking.

This project demonstrates how to take a language model from prototype to production by addressing the real challenges: performance optimization, comprehensive monitoring, structured logging, and load testing.

## Why This Architecture?

### The Problem
Most ML demos run models in Jupyter notebooks with `print()` statements. That's fine for research, but production systems need:
- **Observability**: What's happening inside your service right now?
- **Performance metrics**: How fast are responses? Where are bottlenecks?
- **Structured logging**: Searchable, filterable logs for debugging
- **Load handling**: Will it survive 50 concurrent users?

### Our Solution
We built a full monitoring stack around DistilGPT2 that tracks everything:
- Real-time metrics pushed to Grafana Cloud
- ELK stack for structured log analysis
- Response caching for 11x throughput improvement
- Load testing showing system limits

## Architecture Overview

```
User Request → NGINX Load Balancer → FastAPI (ONNX Runtime) → Response
                                      ↓
                              Prometheus Metrics → Grafana Cloud
                              Logstash → Elasticsearch → Kibana
```

### Key Design Decisions

**1. DistilGPT2 + ONNX instead of vLLM**
- **Why**: Runs on CPU (M2 Mac), no GPU quota needed
- **Trade-off**: Slower per-request, but caching fixes this
- **Result**: 30.7 req/s with 14ms latency after optimization

**2. Response Caching**
- **Why**: Autoregressive generation is slow (50+ tokens = 13+ seconds)
- **Implementation**: MD5-based cache with 100-entry limit
- **Impact**: 11x throughput increase (2.3 → 30.7 req/s)

**3. Prometheus + Grafana Cloud instead of local Grafana**
- **Why**: Easier to share dashboards, no extra container
- **Trade-off**: Requires API token management
- **Benefit**: Accessible from anywhere, not just localhost

**4. ELK Stack for Logs**
- **Why**: Structured logging beats `print()` statements
- **Use case**: Filter by latency, track error patterns, analyze throughput trends
- **Logstash**: Calculates tokens/second from raw metrics

## Performance Results

### Before Optimization
```
Total Requests: 756
Success Rate: 54% (46% errors)
Average Latency: 13,700ms
Throughput: 2.3 req/s
```

### After Adding Cache + Reducing Tokens (50→20)
```
Total Requests: 8,303
Success Rate: 100%
Average Latency: 14ms
P95 Latency: 32ms
Throughput: 30.7 req/s
```

**Key Insight**: The bottleneck wasn't the model—it was generating 50 tokens for every unique request. Caching repeated prompts and reducing token count made the system 11x faster.

## Quick Start

### Prerequisites
- Docker & Docker Compose
- Python 3.10+
- k6 (for load testing): `brew install k6`

### Run Locally

```bash
# Start all services
docker-compose up -d

# Check service health
curl http://localhost/health

# Test generation
curl -X POST http://localhost/generate \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Once upon a time", "max_new_tokens": 20}'

# View logs in Kibana
open http://localhost:5601

# View Prometheus metrics
open http://localhost:9090
```

### Run Load Tests

```bash
# Basic load test (10→50 users over 4.5 min)
k6 run load-tests/basic-load-test.js

# Stress test (up to 200 users)
k6 run load-tests/stress-test.js

# View results
cat load-test-results.json | python3 -m json.tool
```

## Stack Components

| Service | Port | Purpose |
|---------|------|---------|
| NGINX | 80 | Load balancer & reverse proxy |
| FastAPI | 8000 | Model inference API |
| Prometheus | 9090 | Metrics collection |
| Elasticsearch | 9200 | Log storage |
| Logstash | 5044 | Log processing |
| Kibana | 5601 | Log visualization |

## Monitoring & Observability

### Prometheus Metrics
Automatically tracked by `prometheus-fastapi-instrumentator`:
- `http_request_duration_seconds`: Response time distribution
- `http_requests_total`: Request count by endpoint
- `http_requests_in_progress`: Concurrent requests
- `process_cpu_seconds_total`: CPU usage
- `process_resident_memory_bytes`: Memory consumption

### Custom Metrics (via Middleware)
Logged to ELK on every `/generate` request:
- `latency_ms`: Inference time
- `cpu_usage_percent`: CPU during request
- `memory_mb`: Memory footprint
- `tokens_generated`: Output length
- `throughput_tokens_per_sec`: Calculated by Logstash

### Kibana Dashboards
1. Navigate to http://localhost:5601
2. Create index pattern: `model-api-logs-*`
3. Visualize:
   - Latency over time (line chart)
   - Request volume (bar chart)
   - Error rate (gauge)
   - Throughput distribution (histogram)

### Grafana Cloud
Metrics are pushed to Grafana Cloud for centralized monitoring:
- Real-time request rates
- Latency percentiles (p50, p95, p99)
- Resource utilization trends
- Alerting on error rate spikes

## Project Structure

```
.
├── app.py                    # FastAPI application
├── logging_config.py         # ELK logging setup
├── docker-compose.yml        # Service orchestration
├── Dockerfile                # App container
├── requirements.txt          # Python dependencies
├── prometheus/
│   └── prometheus.yml        # Prometheus config (Grafana Cloud push)
├── logstash/
│   └── logstash.conf         # Log processing pipeline
├── load-tests/
│   ├── basic-load-test.js    # Progressive load test
│   ├── stress-test.js        # Stress test
│   └── README.md             # Load testing guide
└── model_cache/              # Pre-downloaded model weights
```

## Key Learnings

### 1. Caching is Critical
Generating 50 tokens takes 13+ seconds. Even a simple cache (100 entries) gives 11x speedup for repeated queries.

### 2. Observability > Raw Performance
A slightly slower model with full monitoring is way more valuable than a fast black box. When things break (and they will), you need to know why.

### 3. Cloud GPU Quotas Are Real
AWS and GCP both default to 0 GPU quota. For hackathons, optimize for CPU or have quotas pre-approved.

### 4. Load Testing Reveals Truth
Our first test: 46% errors. After optimization: 100% success. You can't know your limits without testing.

### 5. Structured Logging > Print Statements
Searching Kibana for "all requests > 100ms with errors" beats scrolling through terminal logs.

## Future Improvements

- **CI/CD Pipeline**: GitHub Actions for automated testing and deployment
- **Auto-scaling**: Scale FastAPI replicas based on CPU/memory
- **Model Quantization**: INT8 quantization for faster inference
- **Distributed Caching**: Redis for shared cache across replicas
- **A/B Testing**: Compare ONNX vs. TorchScript performance
- **GPU Deployment**: Move to AWS ECS with GPU when quota approved

## Load Test Results

Full results available in `load-test-results.json` after running:
```bash
k6 run load-tests/basic-load-test.js
```

**Test Profile**: Ramp from 10→50 virtual users over 4m30s
- Each user sends requests as fast as possible
- Random prompts from predefined list
- 20 tokens generated per request

**Bottleneck Analysis**:
- **CPU-bound**: ONNX inference uses 100% of available cores
- **Memory**: Stable at ~800MB (model + cache)
- **Cache hit rate**: ~80% after warmup (measured via logs)

## Contact & Attribution

Built for the AWS Annapurna Hackathon demonstrating production ML deployment practices.

**Technologies**: FastAPI, ONNX Runtime, Prometheus, Grafana, ELK Stack, Docker, k6

**Model**: DistilGPT2 (Hugging Face Optimized with ONNX)

---

*This README documents our journey from "let's deploy to AWS with GPU" to "let's build proper monitoring and actually understand our system." The second approach scored better with judges.*
