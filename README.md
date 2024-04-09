# FireFlyCI for Github Actions

FireFlyCI is a command line interface for the FireflyCI Firefly actions

### FireFlyCI Post-Plan
```yaml
- name: FireFlyCI Post-Plan
  uses: gofireflyio/fireflyci@v1.0
  with:
    command: post-plan
    plan-file: plan.json
    workspace: gofirefly/infrastructure-prod
    args: --timeout 180
  env:
    FIREFLY_ACCESS_KEY: ${{ secrets.FIREFLY_ACCESS_KEY }}
    FIREFLY_SECRET_KEY: ${{ secrets.FIREFLY_SECRET_KEY }}
```

### FireFlyCI Post-Apply
```yaml
- name: FireFlyCI Post-Plan
  uses: gofireflyio/fireflyci@v1.0
  with:
    command: post-apply
    plan-file: plan.json
    workspace: gofirefly/infrastructure-prod
    args: --timeout 180
  env:
    FIREFLY_ACCESS_KEY: ${{ secrets.FIREFLY_ACCESS_KEY }}
    FIREFLY_SECRET_KEY: ${{ secrets.FIREFLY_SECRET_KEY }}
```


