/**
 * CloudFront Function: Security Headers Injector
 * ==============================================================================
 * Event Type: viewer-response
 * Runtime: cloudfront-js-2.0 / 1.0
 *
 * Injects modern HTTP security headers into every HTTP response served from the
 * CloudFront CDN edge before returning the response to the client browser.
 * ==============================================================================
 */

function handler(event) {
    var response = event.response;
    var headers = response.headers;

    // 1. HTTP Strict Transport Security (HSTS)
    // Enforces HTTPS connections and preloading in modern browsers (2 years)
    headers['strict-transport-security'] = {
        value: 'max-age=63072000; includeSubDomains; preload'
    };

    // 2. X-Content-Type-Options
    // Prevents MIME-type sniffing attacks (e.g. executing script disguised as image)
    headers['x-content-type-options'] = {
        value: 'nosniff'
    };

    // 3. X-Frame-Options
    // Prevents clickjacking and UI redressing by blocking framing
    headers['x-frame-options'] = {
        value: 'DENY'
    };

    // 4. X-XSS-Protection
    // Legacy filter protection for older web browsers
    headers['x-xss-protection'] = {
        value: '1; mode=block'
    };

    // 5. Referrer-Policy
    // Limits referrer information sent to cross-origin requests
    headers['referrer-policy'] = {
        value: 'strict-origin-when-cross-origin'
    };

    // 6. Content-Security-Policy (CSP)
    // Restricts authorized sources of scripts, styles, images, and frames
    headers['content-security-policy'] = {
        value: "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self';"
    };

    // 7. Permissions-Policy
    // Disables browser hardware APIs (microphone, camera, geolocation)
    headers['permissions-policy'] = {
        value: 'camera=(), microphone=(), geolocation=()'
    };

    return response;
}
