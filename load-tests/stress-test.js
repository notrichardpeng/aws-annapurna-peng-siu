import http from 'k6/http';
import { check, sleep } from 'k6';

// Stress test - push the system to its limits
export const options = {
  stages: [
    { duration: '1m', target: 50 },   // Ramp up to 50 users
    { duration: '2m', target: 100 },  // Ramp up to 100 users
    { duration: '3m', target: 150 },  // Stress level: 150 users
    { duration: '2m', target: 200 },  // Breaking point: 200 users
    { duration: '1m', target: 0 },    // Ramp down
  ],
  thresholds: {
    http_req_duration: ['p(99)<5000'], // 99% under 5s
    http_req_failed: ['rate<0.3'],     // Allow 30% error rate at stress
  },
};

const prompts = [
  'Hello, how are you?',
  'Explain AI',
  'Tell me a story',
  'What is Python?',
];

export default function () {
  const prompt = prompts[Math.floor(Math.random() * prompts.length)];

  const response = http.post(
    'http://localhost/generate',
    JSON.stringify({
      prompt: prompt,
      max_new_tokens: 30,
      temperature: 0.7,
    }),
    {
      headers: { 'Content-Type': 'application/json' },
      timeout: '30s',
    }
  );

  check(response, {
    'status is 200': (r) => r.status === 200,
  });

  sleep(0.5); // Aggressive load
}

export function handleSummary(data) {
  return {
    'stress-test-results.json': JSON.stringify(data, null, 2),
  };
}
