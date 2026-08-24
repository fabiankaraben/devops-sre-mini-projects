/**
 * DANGER: Intentional hardcoded JWT signing secret for testing pre-commit detection.
 */

const jwt = require('jsonwebtoken');

// Hardcoded signing key (Violation)
const jwt_secret = 'super_secret_jwt_hmac_key_9988776655';

function generateAuthToken(user) {
  return jwt.sign({ id: user.id, role: user.role }, jwt_secret, { expiresIn: '1h' });
}

module.exports = {
  generateAuthToken
};
