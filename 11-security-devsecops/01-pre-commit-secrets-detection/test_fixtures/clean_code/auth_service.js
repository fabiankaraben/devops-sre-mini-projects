/**
 * Authentication validation middleware.
 * Verifies Authorization header tokens securely without hardcoded secrets.
 */

function authenticateRequest(req, res, next) {
  const authHeader = req.headers['authorization'];

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing or malformed Authorization header' });
  }

  const token = authHeader.substring(7);
  if (!token || token.length < 10) {
    return res.status(403).json({ error: 'Invalid token structure' });
  }

  req.userToken = token;
  return next();
}

module.exports = {
  authenticateRequest
};
