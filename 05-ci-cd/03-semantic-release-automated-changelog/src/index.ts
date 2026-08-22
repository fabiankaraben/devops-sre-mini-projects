/**
 * Semantic Release Engine - Main Entrypoint & Exports
 */

export * from './commit-parser.js';
export * from './version-calculator.js';

import { parseCommitMessage } from './commit-parser.js';
import { calculateNextRelease, generateReleaseNotes } from './version-calculator.js';

/**
 * Runs a CLI demonstration analyzing a simulated batch of commits.
 */
export function runDemo(): void {
  const mockCommits = [
    'fix(auth): resolve JWT expiration race condition (#102)',
    'feat(metrics): add Prometheus latency histogram exporter (#104)',
    'perf(db): optimize connection pool acquisition timeout',
    'chore: update devDependencies',
  ];

  console.log('--- Conventional Commits Input Batch ---');
  mockCommits.forEach((msg) => console.log(`  • ${msg}`));

  const parsed = mockCommits.map(parseCommitMessage);
  const currentVersion = '1.2.0';
  const calculation = calculateNextRelease(currentVersion, parsed);

  console.log('\n--- Semantic Release Calculation ---');
  console.log(`Current Version : v${calculation.currentVersion}`);
  console.log(`Release Type    : ${calculation.releaseType?.toUpperCase()}`);
  console.log(`Next Version    : v${calculation.nextVersion}`);
  console.log('Trigger Reasons :');
  calculation.reasons.forEach((r) => console.log(`  - ${r}`));

  if (calculation.nextVersion) {
    console.log('\n--- Generated Changelog Notes ---');
    const notes = generateReleaseNotes(calculation.nextVersion, parsed);
    console.log(notes);
  }
}

// Execute demo if called directly
if (process.argv[1] && process.argv[1].endsWith('index.js')) {
  runDemo();
}
