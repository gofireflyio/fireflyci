# FireflyCI for GitHub Actions

FireflyCI is a command line interface for the FireflyCI Firefly actions

### FireflyCI Post-Plan
```yaml
- name: FireflyCI Post-Plan
  uses: gofireflyio/fireflyci@v1.0
  with:
    command: post-plan
    plan-output-file: plan.json
    plan-log-file: plan-log.jsonl
    workspace: gofirefly/infrastructure-prod
  env:
    FIREFLY_ACCESS_KEY: ${{ secrets.FIREFLY_ACCESS_KEY }}
    FIREFLY_SECRET_KEY: ${{ secrets.FIREFLY_SECRET_KEY }}
```

### FireflyCI Post-Apply
```yaml
- name: FireflyCI Post-Apply
  uses: gofireflyio/fireflyci@v1.0
  with:
    command: post-apply
    apply-log-file: apply-log.jsonl
    workspace: gofirefly/infrastructure-prod
  env:
    FIREFLY_ACCESS_KEY: ${{ secrets.FIREFLY_ACCESS_KEY }}
    FIREFLY_SECRET_KEY: ${{ secrets.FIREFLY_SECRET_KEY }}
```


