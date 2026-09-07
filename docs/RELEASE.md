# Release setup

The standalone Xcode project includes an iPhone/iPad app target, shared build/test/archive scheme, app icon, privacy manifest, version/build settings, CloudKit and APNs entitlements, background notification mode, usage descriptions and export configuration. Version starts at **1.0.0 (1)**. Its existing registered iOS identifier is **dev.gan.FinancesApp.iOS**, under team **K3URZZFDQP**.

## Apple configuration

Use the existing iOS App ID, associated with `iCloud.dev.gan.FinanceApp` and Push Notifications. App Store Connect record **Finances Companion** (Apple ID **6809320145**) uses this identifier, English (U.S.), Finance category and SKU `finances-companion-ios`. The Home Screen name remains Finances.

The existing Xcode account successfully used Apple cloud-managed signing to create an App Store-signed IPA and a matching iOS Team Store provisioning profile. A local distribution private key is not required for this path. Ensure the existing container’s schema is deployed to Production before testing a Release/TestFlight build. The signing profile has been provisioned and verified. App Store listing metadata and Production schema promotion are separate steps, not performed by the export script.

Complete the beta description, contact and review details, age rating, support URL and privacy policy URL in App Store Connect. The app stores financial data locally and, when enabled, in the user’s private iCloud database. It includes no advertising or analytics SDK. Review the final distribution privacy answers against the actual app behavior.

## GitHub preparation

Create a repository from this folder when ready and push the generated Xcode project and sources. CI runs tests on pushes to `main` and pull requests. Set up a GitHub environment named **app-store** with these secrets:

| Secret | Value |
| --- | --- |
| `APP_STORE_CONNECT_API_KEY` | Contents of the App Store Connect API `.p8` key |
| `APP_STORE_CONNECT_KEY_ID` | API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | API issuer ID |

The manual **Prepare or Upload TestFlight Build** workflow runs tests, authenticates to Apple with the API key, requests cloud-managed signing, archives with a unique build number, and exports an IPA. The key’s role must permit Certificates, Identifiers & Profiles and cloud-managed distribution signing for this team. The same local signing path has passed with the existing Xcode account; the GitHub API-key path still requires the repository secrets and a first CI run. Leave **upload** unchecked to prepare the artifact only. Check it to upload after configuring the App Store Connect app and Production schema. Processing, beta review and tester distribution happen in App Store Connect afterward.

The workflow uses GitHub’s [macOS 26 image with Xcode 26.6](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md). See Apple’s [upload builds guide](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) for processing and supported toolchains.

Automatic TestFlight delivery on push is deliberately not enabled yet. To enable it later, add a `push` trigger for `main` to the release workflow and change the upload condition to `github.event_name == 'push' || inputs.upload`. Keep the environment protection and passing tests in place.

## Local archive

Open Xcode, select the FinancesiOS scheme and Any iOS Device, then Product → Archive. Choose the configured team for signing. Organizer can distribute to App Store Connect using automatic signing.

Alternatively, `scripts/archive.sh` creates an archive in `build/`. `ExportOptions.plist` is for an automatically signed local archive. CI uses the same automatic export settings with explicit App Store Connect API authentication. Locally, run `scripts/archive.sh -allowProvisioningUpdates` followed by `scripts/export_app_store.sh -allowProvisioningUpdates` to reuse the Xcode account. Apple describes this flow in [cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/) and [automated cloud signing](https://developer.apple.com/videos/play/wwdc2021/10204/).

The owner authorized TestFlight distribution to the Gmail tester on September 6, 2026. `scripts/upload_testflight.sh -allowProvisioningUpdates` uploads the reviewed archive using the existing Xcode account. Apple processing and external beta review follow upload. See `VERIFICATION.md` for current release evidence. GitHub remote creation, API-key secrets and automatic delivery on push remain future setup.
