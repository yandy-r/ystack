---
trigger: glob
description: When working on Python files, apply secret management, input boundaries
  and security checks.
globs: '**/*.py,**/*.pyi'
---

# Python Security

## Secret Management

```python
import os
from dotenv import load_dotenv

load_dotenv()

api_key = os.environ["OPENAI_API_KEY"]  # Raises KeyError if missing
```

## Security Scanning

- Use **bandit** for static security analysis:

  ```bash
  bandit -r src/
  ```

## Reference

For Django projects, keep `CsrfViewMiddleware` enabled, query through the ORM or parameterized `cursor.execute(sql, params)` (never interpolate input into SQL), and enable `SECURE_SSL_REDIRECT`, `SECURE_HSTS_SECONDS`, `SESSION_COOKIE_SECURE`, and `CSRF_COOKIE_SECURE` in production. Validate external inputs, parameterize queries and keep error responses free of sensitive details.
