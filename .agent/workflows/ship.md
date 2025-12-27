---
description: Formats, analyzes, tests, and pushes changes to the repository.
---

// turbo-all

1. Format the code to ensure style consistency
```bash
dart format .
```

2. Run static analysis to catch potential issues
```bash
flutter analyze .
```

3. Execute the test suite
```bash
flutter test
```

4. Stage all modified files
```bash
git add .
```

5. Commit the changes with a default message
> [!NOTE]
> For a custom message, use `git commit -m "your message"` manually before or instead of this step.
```bash
git commit -m "chore: ship updates via workflow"
```

6. Push the committed changes to the remote repository
```bash
git push
```
