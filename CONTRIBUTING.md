# Contributing Guide

Thank you for your interest in contributing to the Airgapped RPM Repository System.

## Getting Started

### Prerequisites

- Linux or macOS development environment
- Docker or Podman
- Python 3.9+
- Git

### Setup Development Environment

```bash
# Clone the repository
git clone https://github.com/your-org/airgapped-rpm-repo.git
cd airgapped-rpm-repo

# Create Python virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Build development containers
make build

# Run tests
make test
```

## Development Workflow

### Branch Strategy

- `main`: Stable release branch
- `develop`: Integration branch for features
- `feature/*`: Feature development branches
- `bugfix/*`: Bug fix branches
- `security/*`: Security fix branches (private until merged)

### Making Changes

1. **Create a branch**:
   ```bash
   git checkout -b feature/your-feature develop
   ```

2. **Make your changes**:
   - Follow existing code style
   - Add tests for new functionality
   - Update documentation as needed

3. **Run quality checks**:
   ```bash
   make lint
   make test
   make security-scan
   ```

4. **Commit with meaningful messages**:
   ```bash
   git commit -m "feat: add new capability

   - Detailed description of changes
   - Reference any issues: Fixes #123"
   ```

5. **Push and create pull request**:
   ```bash
   git push origin feature/your-feature
   ```

## Code Standards

### Shell Scripts

- Use `#!/bin/bash` shebang
- Include shellcheck directives: `# shellcheck shell=bash`
- Use `set -euo pipefail` for safety
- Quote variables: `"${var}"`
- Use functions for reusable code
- Include usage documentation

```bash
#!/bin/bash
# shellcheck shell=bash
#
# Description: Brief description of script purpose
# Usage: script.sh [options]
#

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/logging.sh"
```

### Python Code

- Follow PEP 8 style guide
- Use type hints (Python 3.9+ syntax)
- Include docstrings for modules, classes, and functions
- Use `ruff` for linting
- Use `mypy` for type checking

```python
"""Module description."""

from typing import Optional


def function_name(param: str, optional_param: Optional[int] = None) -> bool:
    """
    Brief description.

    Args:
        param: Description of param.
        optional_param: Description of optional param.

    Returns:
        Description of return value.

    Raises:
        ValueError: When something is wrong.
    """
    pass
```

### YAML Files

- Use 2-space indentation
- Follow `.yamllint.yml` configuration
- Include comments for complex configurations

### Documentation

- Use Markdown format
- Include code examples where helpful
- Keep documentation in sync with code changes
- Use diagrams (ASCII art or Mermaid) for architecture

## Testing

### Running Tests

```bash
# All tests
make test

# Specific test file
pytest tests/test_rpm_utils.py -v

# With coverage
pytest --cov=src tests/
```

### Writing Tests

- Place tests in `tests/` directory
- Mirror source structure: `src/module.py` → `tests/test_module.py`
- Use pytest fixtures for common setup
- Test both success and error cases

```python
"""Tests for module_name."""

import pytest
from src.module_name import function_to_test


class TestFunctionToTest:
    """Tests for function_to_test."""

    def test_success_case(self):
        """Test successful operation."""
        result = function_to_test("valid_input")
        assert result == expected_value

    def test_error_case(self):
        """Test error handling."""
        with pytest.raises(ValueError):
            function_to_test("invalid_input")
```

### Test Data

- Store test fixtures in `tests/fixtures/`
- Use realistic but sanitized data
- Never include real credentials or sensitive information

## Pull Request Process

### Before Submitting

- [ ] Code follows project style guidelines
- [ ] All tests pass (`make test`)
- [ ] Linting passes (`make lint`)
- [ ] Security scan passes (`make security-scan`)
- [ ] Documentation updated if needed
- [ ] Commit messages are clear and follow conventions

### PR Description Template

```markdown
## Summary
Brief description of changes.

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Documentation update
- [ ] Refactoring
- [ ] Security fix

## Testing
Describe testing performed.

## Checklist
- [ ] Tests added/updated
- [ ] Documentation updated
- [ ] No security vulnerabilities introduced
```

### Review Process

1. Automated CI checks must pass
2. At least one maintainer approval required
3. Security-related changes require security review
4. Changes to GPG/signing code require additional scrutiny

## Commit Message Convention

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): subject

body

footer
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Formatting, no code change
- `refactor`: Code change that neither fixes nor adds
- `test`: Adding or updating tests
- `chore`: Build process, auxiliary tools

**Examples:**
```
feat(external): add incremental sync support

- Implement delta sync using reposync --newest-only
- Add option to retain multiple package versions
- Update documentation

Closes #45
```

```
fix(verify): handle missing BOM gracefully

Previously, missing BOM file caused unhandled exception.
Now returns clear error message.

Fixes #78
```

## Security Considerations

When contributing, consider:

1. **No Hardcoded Secrets**: Never commit credentials, keys, or tokens
2. **Input Validation**: Validate all external input
3. **Safe Defaults**: Default to secure configurations
4. **Least Privilege**: Request minimal permissions
5. **Audit Logging**: Log security-relevant events

Report security vulnerabilities privately. See [SECURITY.md](SECURITY.md).

## Getting Help

- **Questions**: Open a GitHub Discussion
- **Bugs**: Open a GitHub Issue with reproduction steps
- **Security**: See [SECURITY.md](SECURITY.md)

## License

By contributing, you agree that your contributions will be licensed under the project's license.
