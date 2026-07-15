{ pkgs, ... }:

let
  profileSource = "/var/lib/hermes/.hermes";
  skillsSource = "/var/lib/hermes/.hermes/skills";
  mirrorCheckout = "/var/lib/hermes/hermes-skills-audit";
  mirrorRemote = "https://github.com/fkz/hermes-skills.git";
  credentialSocket = "/run/hermes-github-credential-broker/socket";

  exportHermesSkills = pkgs.writers.writePython3Bin
    "export-hermes-skills" { }
    (builtins.readFile ./hermes-skills/export.py);

  # Read a short-lived installation token from the existing host-side broker.
  # The private App key and unrelated Hermes secrets remain outside this unit.
  skillsGitCredential = pkgs.writers.writePython3Bin
    "hermes-skills-git-credential" { }
    ''
      import socket
      import sys

      if len(sys.argv) > 1 and sys.argv[1] != "get":
          raise SystemExit(0)

      for line in sys.stdin:
          if not line.strip():
              break

      with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
          client.settimeout(70)
          client.connect("${credentialSocket}")
          client.sendall(b"get\n")
          client.shutdown(socket.SHUT_WR)
          while True:
              chunk = client.recv(4096)
              if not chunk:
                  break
              sys.stdout.buffer.write(chunk)
    '';

  mirrorReadme = pkgs.writeText "hermes-skills-readme.md"
    (builtins.readFile ./hermes-skills/README.md);

  syncHermesSkills = pkgs.writeShellApplication {
    name = "sync-hermes-skills";
    runtimeInputs = [ pkgs.coreutils pkgs.git ];
    text = ''
      set -eu
      umask 077

      repo=${mirrorCheckout}
      remote=${mirrorRemote}
      helper=${skillsGitCredential}/bin/hermes-skills-git-credential

      git_auth() {
        git -c credential.helper= \
          -c "credential.https://github.com.helper=$helper" "$@"
      }

      install -d -m 0700 "$repo"
      if ! test -d "$repo/.git"; then
        git -C "$repo" init -b main
        git -C "$repo" remote add origin "$remote"
      fi

      git -C "$repo" config user.name "hpr-bot[bot]"
      git -C "$repo" config user.email \
        "hpr-bot[bot]@users.noreply.github.com"

      if git_auth -C "$repo" ls-remote --exit-code --heads \
        origin main >/dev/null; then
        git_auth -C "$repo" fetch origin main
        if git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
          git -C "$repo" merge --ff-only origin/main
        else
          git -C "$repo" checkout -B main origin/main
        fi
      fi

      if ! test -e "$repo/README.md"; then
        install -m 0600 ${mirrorReadme} "$repo/README.md"
      fi

      ${exportHermesSkills}/bin/export-hermes-skills \
        ${skillsSource} ${profileSource} "$repo"
      git -C "$repo" add README.md CATALOG.md metadata profile skills

      if git -C "$repo" diff --cached --quiet; then
        echo "Hermes skill mirror is already current."
        exit 0
      fi

      git -C "$repo" commit -m "chore: snapshot Hermes profile"
      git_auth -C "$repo" push -u origin HEAD:main
    '';
  };
in
{
  systemd.tmpfiles.rules = [
    "d ${mirrorCheckout} 0700 hermes hermes -"
  ];

  systemd.services.hermes-skills-audit = {
    description = "Export local Hermes skills to a private Git audit mirror";
    after = [
      "network-online.target"
      "hermes-github-credential-broker.socket"
    ];
    wants = [ "network-online.target" ];
    requires = [ "hermes-github-credential-broker.socket" ];

    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      ExecStart = "${syncHermesSkills}/bin/sync-hermes-skills";
      TimeoutStartSec = "5min";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ mirrorCheckout ];
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    };

    environment.HOME = "/var/lib/hermes";
  };

  systemd.timers.hermes-skills-audit = {
    description = "Regularly snapshot local Hermes skills to GitHub";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "15min";
      RandomizedDelaySec = "2min";
      Unit = "hermes-skills-audit.service";
    };
  };
}
