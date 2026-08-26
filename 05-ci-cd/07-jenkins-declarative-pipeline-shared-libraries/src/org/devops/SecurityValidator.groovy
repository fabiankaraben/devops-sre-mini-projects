package org.devops

class SecurityValidator implements Serializable {
    private Object script

    SecurityValidator(Object script) {
        this.script = script
    }

    boolean assertSecretMasked(String secretValue, String logContent) {
        if (!secretValue || secretValue.length() < 4) {
            script.echo "[SECURITY] Skipping check: secret token is too short or empty."
            return true
        }

        if (logContent.contains(secretValue)) {
            script.error "[SECURITY FATAL] Secret value was leaked in plaintext within console output!"
            return false
        }

        script.echo "\u001B[32m[SECURITY AUDIT PASS]\u001B[0m Secret value remained masked (****) in build logs."
        return true
    }
}
