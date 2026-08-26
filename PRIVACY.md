# Privacy Policy
This privacy policy governs your use of the GitHub app "Todo PR Checker" (hereby, "app"), developed by Nikkel Mollenhauer (hereby, "we", "us", "our", "developer).
The functionality of GitHub apps builds upon GitHub infrastructure, and as such, some data is processed by and transmitted from and/or to GitHub as part of the app's functionality.
If you have any questions about how your data is processed by GitHub, please refer to the GitHub privacy policy.

# What information does the app obtain and how is it used?
The app is granted a set of permissions to be notified of events in the repository or repositories you grant it access to.
These permissions are presented to you when you first install the app, where you must grant them in order for the app to function.
Whenever these permissions change, you will be notified and required to accept the change before the app will continue to function.
The permissions requested by the app are kept as minimal as possible, and are only used to deliver the functionality of the app.

When you perform certain actions in repositories to which the app has access (including, but not limited to, creating or updating a Pull Request), the app is notified of these actions through a webhook.
The information transmitted through these webhooks is secured by GitHub, and only readable by the app and authorized employees.
The webhooks contain information pertaining to the action you took, such as the file changes in a Pull Request.
The app uses this data to perform its function, and for no other reason.

Depending on the configuration you provide in your repository, the app writes content back to your repository as part of its function.
This is limited to check runs and their annotations, comments on Pull Requests, and, if you enable the `create_issues` option, issues describing the action items that were found.
Content is only ever written to the repository the webhook originated from, and only contains information derived from that repository and the Pull Request being checked.

The app does not persist the content of any webhook beyond the duration of a request (where a "request" hereby is the reception, processing of, and response to, a webhook as described above).
File changes, Pull Request content, and any other payload content are held in memory for the duration of the request only, and are never written to storage.

To operate the app reliably, and to detect abnormal traffic volumes that would otherwise degrade or interrupt the service, the app records a minimal technical log entry for each webhook it receives.
This entry contains only the type of the event, the action it describes, the identifier of the GitHub App that created the check run an event relates to, and whether the app acted on the event or ignored it.
It does not contain repository names or identifiers, installation or account identifiers, or content from the webhook payload.

# Do third parties see and/or have access to information obtained by the app?
The app leverages Google Cloud services to build, deploy and host the app and deliver its functionality.
This means that any webhooks as described above are transmitted to and processed by Google Cloud services.
The technical log entries described above, and the standard request logs that Google Cloud produces as part of hosting the app, are stored by Google Cloud for the retention period set out below.
Beyond the scope of delivering the app's functionality, the data is not used in any other way by Google Cloud services, and not shared with any other third parties.

# Data Retention Policy
No webhook payload content is retained in any form.
Payload content is used only during the duration of a request, and is not stored in any way.

The technical log entries described above, together with the standard request logs produced by Google Cloud as part of hosting the app (comprising the time of the request, the response status, the duration of the request, and the network address and user agent of the sending GitHub service), are retained for a limited period and are then deleted automatically.
The current retention period is 30 days.

Separately, GitHub itself retains a record of the webhooks it has delivered to the app, which is accessible to the developer through GitHub's own interfaces.
Where abnormal traffic has to be investigated, the developer may inspect that record through GitHub.
Data viewed in this way is not incorporated into the app or into any persistent store, and any temporary copy made in the course of an investigation is deleted once that investigation concludes.

# Security
We are concerned about safeguarding the confidentiality of your information. 
We limit access to this information to authorized employees who need access to the information in order to operate, develop or improve the app. 
Please be aware that, although we endeavor to provide reasonable security for information we process and maintain, no security system can prevent all potential security breaches.

# Changes to the Policy
This Privacy Policy may be updated from time to time for any reason. 
We will notify you of any changes to our Privacy Policy by posting the new Privacy Policy here. 
You are advised to consult this Privacy Policy regularly for any changes, as continued use is deemed approval of all changes.

# Contact
If you have any questions regarding this privacy policy or your usage of the app, or have questions about our practices, please contact us via email at contact[at]nikkelm.dev.
