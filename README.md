<p align="center">
  <img src="Resources/icon.png" width="128" alt="AWSContext icon">
</p>

<h1 align="center">AWSContext</h1>

<p align="center">Switch AWS profiles from the macOS menu bar.</p>

---

AWSContext puts your AWS profile in the menu bar. Click a profile to make it active for **every** terminal, SDK and tool. You don't need to export variables or restart shells.

- **Switch with one click**, or press <kbd>⌘1</kbd>…<kbd>⌘9</kbd> while the menu is open. <kbd>⌘P</kbd> jumps back to the profile you used before
- **Open the AWS Console** (<kbd>⌘O</kbd>) signed in to that account, role and region, in your default browser
- **Knows when SSO sessions expire**: shows the time left, switches the icon to a warning, notifies you, and signs you in again (<kbd>⌘L</kbd>) with `aws sso login`. Switching to an expired profile signs in automatically
- **Shows the active profile** in the menu bar so you always know where you are
- **Add a profile in seconds**: paste what the AWS access portal gives you (`export AWS_…` lines, a `[profile]` credentials block or STS JSON) and the form fills itself
- **Uses your existing files**: `~/.aws/credentials` and `~/.aws/config`, including SSO, assume-role and `credential_process` profiles
- **Preserves your files**: comments and formatting stay as they are, and a backup is made before the first change
- Launch at login, follows edits made outside the app, no dependencies, MIT licensed

## Install

### Download

1. Get `AWSContext-vX.Y.Z.zip` from [Releases](../../releases) and move `AWSContext.app` to `/Applications`.
2. The build isn't notarized, so on first launch either right-click the app and choose **Open**, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/AWSContext.app
   ```

### Build from source

Requires macOS 13+ and Xcode 15+.

```sh
git clone https://github.com/petricbranko/awscontext.git
cd awscontext
make install   # builds and copies AWSContext.app to /Applications
```

## How it works

AWS tools read the `[default]` profile when `AWS_PROFILE` isn't set. When you pick a profile, AWSContext copies its settings into `[default]` in both `credentials` and `config`, so the next AWS command anywhere uses it.

Your data stays safe:

- If your `[default]` profile was written by hand and doesn't match any other profile, it is first saved as a new profile named **`default-backup`**, so you can switch back to it at any time.
- Before the first write, the original files are copied to `credentials.awscontext-backup` and `config.awscontext-backup`.
- Only the sections that change are rewritten. Comments, ordering and nested settings are left alone, and `credentials` stays `chmod 600`.

The active profile name is also written to `~/.aws/awscontext`, which you can show in your shell prompt:

```sh
# zsh
RPROMPT='☁ $(cat ~/.aws/awscontext 2>/dev/null)'
```

> **Note:** if `AWS_PROFILE` or `AWS_ACCESS_KEY_ID` is set in your shell, it overrides `[default]`. Unset it so AWSContext can take effect.

AWSContext respects `AWS_SHARED_CREDENTIALS_FILE` and `AWS_CONFIG_FILE` when it is launched with them set.

## FAQ

**Does it support AWS SSO / IAM Identity Center?**
Yes. SSO profiles in `~/.aws/config` appear in the list and can be switched to. Log in as usual with `aws sso login`.

**How does "Open AWS Console" work?**
For SSO profiles it opens your access portal's shortcut link for that account and role, so the browser handles the login. For other profiles it gets temporary credentials from the AWS CLI (`aws configure export-credentials`, or `aws sts get-federation-token` for IAM user keys) and exchanges them for a console sign-in link at `signin.aws.amazon.com`. Only the commercial AWS partition is supported for now.

**Does it send my credentials anywhere?**
Only to AWS, and only when you ask: "Open AWS Console" for non-SSO profiles sends temporary credentials to AWS's own sign-in endpoint. For an active SSO profile whose token needs renewing, the app runs `aws sts get-caller-identity` at most every 10 minutes to check the session is still alive. Nothing goes anywhere else.

**What does it need?**
The [AWS CLI v2](https://aws.amazon.com/cli/) for SSO sign-in and the console for non-SSO profiles. Switching profiles works without it.

**How do I go back to how things were?**
Switch to `default-backup`, or restore the `*.awscontext-backup` files.

## Contributing

Issues and PRs are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
