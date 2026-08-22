import { describe, it, expect } from 'vitest';
import { parseCommitMessage } from '../src/commit-parser.js';
import {
  parseSemVer,
  formatSemVer,
  calculateNextRelease,
  generateReleaseNotes,
} from '../src/version-calculator.js';

describe('Semantic Version Calculator', () => {
  describe('parseSemVer & formatSemVer', () => {
    it('should parse valid SemVer strings with or without v prefix', () => {
      expect(parseSemVer('1.2.3')).toEqual({ major: 1, minor: 2, patch: 3 });
      expect(parseSemVer('v2.0.1')).toEqual({ major: 2, minor: 0, patch: 1 });
    });

    it('should format SemVer objects into strings', () => {
      expect(formatSemVer({ major: 3, minor: 1, patch: 4 })).toBe('3.1.4');
    });

    it('should throw on invalid version strings', () => {
      expect(() => parseSemVer('1.2')).toThrow(Error);
      expect(() => parseSemVer('invalid')).toThrow(Error);
    });
  });

  describe('calculateNextRelease', () => {
    it('should calculate patch release for fix / perf commits', () => {
      const commits = [
        parseCommitMessage('fix: resolve memory leak'),
        parseCommitMessage('perf: optimize loop execution'),
      ];
      const result = calculateNextRelease('1.0.0', commits);
      expect(result.releaseType).toBe('patch');
      expect(result.nextVersion).toBe('1.0.1');
    });

    it('should calculate minor release when feat commits are present', () => {
      const commits = [
        parseCommitMessage('fix: minor bug fix'),
        parseCommitMessage('feat: add support for Redis caching'),
      ];
      const result = calculateNextRelease('1.0.0', commits);
      expect(result.releaseType).toBe('minor');
      expect(result.nextVersion).toBe('1.1.0');
    });

    it('should calculate major release when breaking change is present', () => {
      const commits = [
        parseCommitMessage('feat: add new API endpoint'),
        parseCommitMessage('feat!: remove deprecated v1 REST routes'),
      ];
      const result = calculateNextRelease('1.2.3', commits);
      expect(result.releaseType).toBe('major');
      expect(result.nextVersion).toBe('2.0.0');
    });

    it('should return null nextVersion when only non-triggering commits exist (docs, chore, test)', () => {
      const commits = [
        parseCommitMessage('docs: update README installation steps'),
        parseCommitMessage('chore: update linter rules'),
      ];
      const result = calculateNextRelease('1.0.0', commits);
      expect(result.releaseType).toBeNull();
      expect(result.nextVersion).toBeNull();
    });
  });

  describe('generateReleaseNotes', () => {
    it('should generate categorized markdown changelog', () => {
      const commits = [
        parseCommitMessage('feat(auth): support OAuth2 PKCE login (#10)'),
        parseCommitMessage('fix(db): correct SQL pool connection count'),
        parseCommitMessage('perf: speed up JSON serialization'),
      ];
      const notes = generateReleaseNotes('1.1.0', commits, '2026-08-21');
      expect(notes).toContain('# [1.1.0] - 2026-08-21');
      expect(notes).toContain('### ✨ Features');
      expect(notes).toContain('- **auth**: support OAuth2 PKCE login (#10)');
      expect(notes).toContain('### 🐛 Bug Fixes');
      expect(notes).toContain('### ⚡ Performance Improvements');
    });

    it('should include breaking changes section if present', () => {
      const commits = [
        parseCommitMessage('feat!: drop Node 16 support\n\nBREAKING CHANGE: Minimum required Node version is 18.'),
      ];
      const notes = generateReleaseNotes('2.0.0', commits, '2026-08-21');
      expect(notes).toContain('### ⚠️ BREAKING CHANGES');
      expect(notes).toContain('Minimum required Node version is 18.');
    });
  });
});
