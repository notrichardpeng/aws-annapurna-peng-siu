# Load Testing with k6

## Installation

```bash
# macOS
brew install k6

# Or via official script
brew install k6
```

## Running Tests

### 1. Start the Application Stack

```bash
docker-compose up -d
```

Wait for services to be ready (~2 minutes).

### 2. Basic Load Test

Test with gradually increasing load (10 → 50 users):

```bash
k6 run load-tests/basic-load-test.js
```

### 3. Stress Test

Push system to limits (up to 200 concurrent users):

```bash
k6 run load-tests/stress-test.js
```

### 4. Export to Grafana Cloud (Optional)

```bash
# Set your Grafana Cloud token
export K6_CLOUD_TOKEN=your-token-here

# Run with cloud output
k6 run --out cloud load-tests/basic-load-test.js
```

## Test Scenarios

### Basic Load Test
- **Duration**: 4.5 minutes
- **Max Users**: 50 concurrent
- **Pattern**: Gradual ramp-up
- **Purpose**: Normal operating conditions

### Stress Test
- **Duration**: 9 minutes
- **Max Users**: 200 concurrent
- **Pattern**: Progressive stress
- **Purpose**: Find breaking points

## Interpreting Results

### Key Metrics

- **http_req_duration**: Response time
  - p(95): 95th percentile (most important)
  - p(99): 99th percentile (outliers)

- **http_req_failed**: Error rate
  - Should be < 1% under normal load
  - < 10% under stress

- **http_reqs**: Throughput
  - Requests per second
  - Higher is better

### Example Output

```
scenarios: (100.00%) 1 scenario, 50 max VUs, 5m0s max duration

✓ status is 200
✓ response has generated_text
✓ response time < 2000ms

http_req_duration..............: avg=450ms  p(95)=850ms  p(99)=1200ms
http_req_failed................: 0.50%
http_reqs......................: 1200 (requests)
iteration_duration.............: avg=1.5s
vus............................: 10-50 (concurrent users)
```

## Viewing Real-time Metrics

While tests are running, view metrics at:

- **Prometheus**: http://localhost:9090
- **Kibana**: http://localhost:5601
- **Application logs**: `docker logs -f aws-annapurna-peng-siu-model-api-1`

## Export Results

Results are automatically saved to:
- `load-test-results.json` (JSON format for analysis)
- Console output (human-readable summary)

## Tips

1. **Baseline first**: Run with 1-10 users to establish baseline
2. **Monitor resources**: Watch CPU/memory in Docker Desktop
3. **Check logs**: Look for errors during high load
4. **Multiple runs**: Run tests 3 times, use median results
5. **Document findings**: Note when system starts degrading
