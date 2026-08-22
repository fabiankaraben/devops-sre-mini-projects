import { describe, it, expect } from 'vitest';
import { parseCommitMessage, extractIssueReferences } from '../src/commit-parser.js';

describe('Conventional Commit Parser', () => {
  it('should parse standard feat commit without scope', () => {
    const result = parseCommitMessage('feat: add user authentication endpoint');
    expect(result.type).toBe('feat');
    expect(result.scope).toBeNull();
    expect(result.description).toBe('add user authentication endpoint');
    expect(result.isBreaking).toBe(false);
  });

  it('should parse scoped fix commit with issue reference', () => {
    const result = parseCommitMessage('fix(database): prevent connection leak during timeout (#45)');
    expect(result.type).toBe('fix');
    expect(result.scope).toBe('database');
    expect(result.description).toBe('prevent connection leak during timeout (#45)');
    expect(result.issueReferences).toEqual(['#45']);
  });

  it('should identify breaking change with exclamation mark syntax (feat!)', () => {
    const result = parseCommitMessage('feat(api)!: migrate payload format to protobuf');
    expect(result.type).toBe('feat');
    expect(result.scope).toBe('api');
    expect(result.isBreaking).toBe(true);
  });

  it('should identify breaking change with multiline BREAKING CHANGE footer', () => {
    const msg = `refactor(config): switch from JSON to YAML

BREAKING CHANGE: The config parser no longer supports .json files.`;
    const result = parseCommitMessage(msg);
    expect(result.type).toBe('refactor');
    expect(result.isBreaking).toBe(true);
    expect(result.breakingDescription).toBe('The config parser no longer supports .json files.');
  });

  it('should classify non-conventional commits as other', () => {
    const result = parseCommitMessage('Updated README and fixed typo');
    expect(result.type).toBe('other');
    expect(result.description).toBe('Updated README and fixed typo');
    expect(result.isBreaking).toBe(false);
  });

  it('should extract multiple issue numbers and PR keys', () => {
    const refs = extractIssueReferences('Fixes #12, closes GH-456 and addresses #12');
    expect(refs).toContain('#12');
    expect(refs).toContain('GH-456');
    expect(refs.length).toBe(2); // Set deduplication
  });

  it('should reject empty or invalid commit message inputs', () => {
    expect(() => parseCommitMessage('')).toThrow(TypeError);
    // @ts-expect-error Testing invalid input
    expect(() => parseCommitMessage(null)).toThrow(TypeError);
  });
});
