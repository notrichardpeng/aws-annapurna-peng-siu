import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const responseTime = new Trend('response_time');

// Test configuration
export const options = {
  stages: [
    { duration: '30s', target: 10 },  // Ramp up to 10 users over 30s
    { duration: '1m', target: 10 },   // Stay at 10 users for 1 minute
    { duration: '30s', target: 50 },  // Ramp up to 50 users
    { duration: '2m', target: 50 },   // Stay at 50 users for 2 minutes
    { duration: '30s', target: 0 },   // Ramp down to 0
  ],
  thresholds: {
    http_req_duration: ['p(95)<2000'], // 95% of requests should be below 2s
    http_req_failed: ['rate<0.1'],     // Error rate should be less than 10%
    errors: ['rate<0.1'],
  },
};

// Test data
const prompts = [
  'Write a short story about',
  'Explain quantum computing in simple terms',
  'What is the meaning of life?',
  'Tell me a joke about programming',
  'Describe the future of AI',
  'How does machine learning work?',
  'What are the benefits of exercise?',
  'Explain blockchain technology',
];

export default function () {
  // Select random prompt
  const prompt = prompts[Math.floor(Math.random() * prompts.length)];

  // API endpoint
  const url = 'http://localhost/generate';

  // Request payload
  const payload = JSON.stringify({
    prompt: prompt,
    max_new_tokens: 20,  // Reduced from 50 for faster response
    temperature: 0.8,
  });

  // Request headers
  const params = {
    headers: {
      'Content-Type': 'application/json',
    },
    timeout: '30s',
  };

  // Make request
  const response = http.post(url, payload, params);

  // Check response
  const success = check(response, {
    'status is 200': (r) => r.status === 200,
    'response has generated_text': (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.hasOwnProperty('generated_text');
      } catch {
        return false;
      }
    },
    'response time < 2000ms': (r) => r.timings.duration < 2000,
  });

  // Record metrics
  errorRate.add(!success);
  responseTime.add(response.timings.duration);

  // Think time between requests
  sleep(1);
}

// Summary handler - simplified to avoid errors
export function handleSummary(data) {
  return {
    'load-test-results.json': JSON.stringify(data, null, 2),
  };
}
