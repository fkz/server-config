{ ... }:

{
  # Hermes runs as a dedicated, unprivileged system user and persists its
  # sessions, skills, memory, and gateway state in /var/lib/hermes.
  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;

    settings = {
      # OpenAI Codex OAuth is used instead of an API key. The authenticated
      # credential is stored outside the repository in Hermes' state directory.
      model = {
        default = "gpt-5.6-terra";
        provider = "openai-codex";
        base_url = "https://chatgpt.com/backend-api/codex";
      };

      terminal = {
        backend = "local";
        timeout = 180;
      };

      memory = {
        memory_enabled = true;
        user_profile_enabled = true;
      };
    };

    # Bootstrap the OpenAI Codex OAuth login on the server after deployment:
    #   sudo -u hermes HERMES_HOME=/var/lib/hermes/.hermes hermes auth add openai-codex
    # The resulting auth.json stays in /var/lib/hermes/.hermes and is preserved
    # across NixOS rebuilds.
  };
}
