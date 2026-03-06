# MIBC Profiles for Apple Platforms

## Source

MIBC profiles are produced by the `dotnet-optimization` pipeline in Azure DevOps (`dnceng/internal`).

- **Maestro channel**: [Channel 5172](https://maestro.dot.net/channel/5172/azdo:dnceng:internal:dotnet-optimization/build/latest)
- **Pipeline**: `dotnet-optimization` in `dnceng/internal/_git/dotnet-optimization`
- **Artifact naming**: `CLRx64LIN-x64ANDmasIBC_CLRx64LIN-x64AND` (Android example — Apple artifact names TBD)

## How to Download

```bash
# Get latest build ID from the channel
# Then download the artifact:
TOKEN=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv)
curl -s -L -o ibc-artifact.zip -H "Authorization: Bearer $TOKEN" \
  "https://dev.azure.com/dnceng/{projectId}/_apis/build/builds/{buildId}/artifacts?artifactName={artifactName}&api-version=7.0&%24format=zip"
```

## Profile Usage in This Repo

- Profiles are stored in `profiles/` (gitignored — not checked in)
- `generate-apps.sh` copies `profiles/*.mibc` into each app's `profiles/` directory during generation
- The app csproj patches include `<_ReadyToRunPgoFiles Include="profiles/*.mibc" />` for R2R_COMP_PGO builds
- MAUI apps override `_MauiUseDefaultReadyToRunPgoFiles=false` to use our profiles instead of MAUI defaults

## Android Profile Details (Reference)

- Training flow: EventPipe trace → `dotnet-pgo create-mibc` (per trace) → `dotnet-pgo merge` (per scenario)
- `--include-reference` whitelist filter during merge controls which assemblies survive
- Known issue: MAUI/AndroidX/Google assemblies were filtered out (fixed in dotnet-optimization PR #58455)

## Apple Platform Considerations

- iOS/macOS MIBC profiles may use different artifact names in the pipeline
- Need to verify whether `dotnet-optimization` currently produces Apple platform profiles
- If not available, profiles can be collected locally using `dotnet-trace` + `dotnet-pgo create-mibc`
- The `--partial` crossgen2 flag is important when profiles don't cover all methods
