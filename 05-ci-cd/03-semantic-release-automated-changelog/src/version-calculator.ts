/**
 * Semantic Version Calculator and Release Notes Generator
 */

import { ParsedCommit } from './commit-parser.js';

export type ReleaseType = 'major' | 'minor' | 'patch' | null;

export interface SemVer {
  major: number;
  minor: number;
  patch: number;
}

export interface ReleaseCalculation {
  currentVersion: string;
  nextVersion: string | null;
  releaseType: ReleaseType;
  reasons: string[];
}

/**
 * Parses a semantic version string into major, minor, and patch numbers.
 */
export function parseSemVer(versionStr: string): SemVer {
  const clean = versionStr.replace(/^v/, '').trim();
  const match = clean.match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!match) {
    throw new Error(`Invalid SemVer format: ${versionStr} (expected X.Y.Z)`);
  }
  return {
    major: parseInt(match[1], 10),
    minor: parseInt(match[2], 10),
    patch: parseInt(match[3], 10),
  };
}

/**
 * Formats SemVer object into a standard version string.
 */
export function formatSemVer(semver: SemVer): string {
  return `${semver.major}.${semver.minor}.${semver.patch}`;
}

/**
 * Calculates the next semantic release bump based on a list of analyzed commits.
 */
export function calculateNextRelease(
  currentVersion: string,
  commits: ParsedCommit[]
): ReleaseCalculation {
  const current = parseSemVer(currentVersion);
  let bump: ReleaseType = null;
  const reasons: string[] = [];

  for (const commit of commits) {
    if (commit.isBreaking) {
      bump = 'major';
      reasons.push(`Breaking change: "${commit.description}"`);
      break; // Major is the highest possible bump
    } else if (commit.type === 'feat') {
      bump = 'minor';
      reasons.push(`New feature: "${commit.description}"`);
    } else if (['fix', 'perf', 'revert'].includes(commit.type)) {
      if (bump === null) {
        bump = 'patch';
      }
      reasons.push(`Bug fix / optimization: "${commit.description}"`);
    }
  }

  if (bump === null) {
    return {
      currentVersion: formatSemVer(current),
      nextVersion: null,
      releaseType: null,
      reasons: ['No release-triggering commits found (e.g. only docs, chore, test)'],
    };
  }

  const next: SemVer = { ...current };
  if (bump === 'major') {
    next.major += 1;
    next.minor = 0;
    next.patch = 0;
  } else if (bump === 'minor') {
    next.minor += 1;
    next.patch = 0;
  } else if (bump === 'patch') {
    next.patch += 1;
  }

  return {
    currentVersion: formatSemVer(current),
    nextVersion: formatSemVer(next),
    releaseType: bump,
    reasons,
  };
}

/**
 * Generates formatted Markdown release notes for a batch of commits.
 */
export function generateReleaseNotes(
  version: string,
  commits: ParsedCommit[],
  dateStr = new Date().toISOString().split('T')[0]
): string {
  const breakingList: string[] = [];
  const featureList: string[] = [];
  const fixList: string[] = [];
  const perfList: string[] = [];
  const otherList: string[] = [];

  for (const c of commits) {
    const scopePrefix = c.scope ? `**${c.scope}**: ` : '';
    // Append issue references only if not already in the description text
    const unmentionedIssues = c.issueReferences.filter((ref) => !c.description.includes(ref));
    const issueSuffix = unmentionedIssues.length > 0 ? ` (${unmentionedIssues.join(', ')})` : '';
    const item = `- ${scopePrefix}${c.description}${issueSuffix}`;

    if (c.isBreaking) {
      const breakDesc = c.breakingDescription ? `: ${c.breakingDescription}` : '';
      breakingList.push(`- **BREAKING CHANGE**${breakDesc} (in ${c.description})`);
    }

    if (c.type === 'feat') {
      featureList.push(item);
    } else if (c.type === 'fix') {
      fixList.push(item);
    } else if (c.type === 'perf') {
      perfList.push(item);
    } else {
      otherList.push(item);
    }
  }

  const sections: string[] = [`# [${version}] - ${dateStr}\n`];

  if (breakingList.length > 0) {
    sections.push('### ⚠️ BREAKING CHANGES\n\n' + breakingList.join('\n') + '\n');
  }
  if (featureList.length > 0) {
    sections.push('### ✨ Features\n\n' + featureList.join('\n') + '\n');
  }
  if (fixList.length > 0) {
    sections.push('### 🐛 Bug Fixes\n\n' + fixList.join('\n') + '\n');
  }
  if (perfList.length > 0) {
    sections.push('### ⚡ Performance Improvements\n\n' + perfList.join('\n') + '\n');
  }

  return sections.join('\n');
}
