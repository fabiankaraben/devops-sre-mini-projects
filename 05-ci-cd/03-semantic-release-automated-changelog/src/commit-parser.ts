/**
 * Conventional Commits Parser
 * Adheres to the Conventional Commits 1.0.0 Specification
 */

export interface ParsedCommit {
  raw: string;
  type: string;
  scope: string | null;
  description: string;
  body: string | null;
  isBreaking: boolean;
  breakingDescription: string | null;
  issueReferences: string[];
}

const CONVENTIONAL_COMMIT_REGEX = /^([a-zA-Z0-9_-]+)(?:\(([^)]+)\))?(!)?:\s+(.+)$/;

/**
 * Parses a commit message into structured Conventional Commit metadata.
 */
export function parseCommitMessage(message: string): ParsedCommit {
  if (typeof message !== 'string' || !message.trim()) {
    throw new TypeError('Commit message must be a non-empty string');
  }

  const lines = message.trim().split('\n');
  const header = lines[0].trim();
  const bodyLines = lines.slice(1).map((l) => l.trim()).filter((l) => l.length > 0);
  const body = bodyLines.length > 0 ? bodyLines.join('\n') : null;

  const match = header.match(CONVENTIONAL_COMMIT_REGEX);
  if (!match) {
    return {
      raw: message,
      type: 'other',
      scope: null,
      description: header,
      body,
      isBreaking: false,
      breakingDescription: null,
      issueReferences: extractIssueReferences(message),
    };
  }

  const [, type, scope, breakingBang, description] = match;
  let isBreaking = Boolean(breakingBang);
  let breakingDescription: string | null = null;

  // Check for multiline BREAKING CHANGE or BREAKING-CHANGE footers in body
  for (const line of bodyLines) {
    const breakingMatch = line.match(/^BREAKING[- ]CHANGE:\s*(.+)$/i);
    if (breakingMatch) {
      isBreaking = true;
      breakingDescription = breakingMatch[1].trim();
      break;
    }
  }

  return {
    raw: message,
    type: type.toLowerCase(),
    scope: scope ? scope.trim() : null,
    description: description.trim(),
    body,
    isBreaking,
    breakingDescription,
    issueReferences: extractIssueReferences(message),
  };
}

/**
 * Extracts GitHub issue and PR references (e.g. #123, GH-456).
 */
export function extractIssueReferences(text: string): string[] {
  const matches = text.match(/(?:#|GH-)(\d+)/gi);
  if (!matches) {
    return [];
  }
  return Array.from(new Set(matches));
}
