# Contributing to RepoRaccoon

Contributors are welcome! Feel free to improve the app and make it more useful for everyone. Bug fixes, new features, documentation, and ideas all help.

## Ways to help

- **Report a bug** — open an [issue](https://github.com/riigait/RepoRaccoon/issues) with what you ran, what you expected, and what happened (include `reporaccoon -v` and your Windows version).
- **Suggest an idea** — open an issue describing the problem it solves. The [Roadmap](README.md#roadmap) lists planned work.
- **Send a change** — pull requests of any size are welcome.

## Making a change

1. Fork the repository and create a branch: `git checkout -b my-change`.
2. Make your change. Keep it focused on one thing.
3. Test it:
   - Run the CLI from the repo folder: `powershell -ExecutionPolicy Bypass -File reporaccoon.ps1 -h`
   - Run the web UI in the foreground: `powershell -ExecutionPolicy Bypass -File reporaccoon.ps1 -w -fg`
   - Check it works on **Windows PowerShell 5.1** (the version built into Windows), not only PowerShell 7.
4. Update `README.md` if you add or change an option.
5. Open a pull request with a short description of what changed and why.

## Guidelines

- No extra installs: the app uses only what ships with Windows (PowerShell 5.1, `HttpListener`, plain HTML/CSS/JS).
- Keep the web UI local-only and safe: it listens on `localhost` and only opens paths from scan results.
- Never commit secrets, tokens, or personal scan results (`cache.json`).
- Match the existing code style.

## License and branding

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE). Please read the [Name and branding](README.md#name-and-branding) notice before distributing a modified version.
