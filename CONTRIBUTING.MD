# Contributing to repocopy

First off, thanks for taking the time to contribute!

## How to report a bug

1. **Search existing issues** – your bug may already be fixed or reported.  
2. **Open a _Bug report_ issue** using the template.  
3. Include:
   * Steps to reproduce
   * Expected vs. actual behaviour
   * Your OS / shell / repocopy version

## How to request a feature

Open a _Feature request_ issue and describe:
* The problem you’re trying to solve
* A concise proposal (CLI flag, behaviour change, …)
* Any alternatives you considered

## Pull-request guidelines

* One logical change per PR
* Run `./ci-local-test.sh` (Bats & Pester) – all tests must pass
* Follow existing code style; bash-strict mode & PowerShell `Set-StrictMode`
* Add tests for new behaviour
