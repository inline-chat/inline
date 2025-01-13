/// This should persist changes that need to be retried even if app quits
/// Each transaction will have an option to specifiy how long it should be preserved.
/// eg.
/// - transient updates like setOnline or typing don't need retry at all.
/// - message send should be kept in cache for 30 min even on quit (?)
/// - archiving a channel should be retried indefinitely until success.
///
/// Failure case should be handled in the transaction to revert the change in cache or something custom eg. for sending message we will mark the message as failed to send and show a resend button.
///
/// We will mark a transaction as done when API responds `ok`: true
/// If API responds `ok`: false, we will retry the transaction after a delay if the error is type FLOOD or INTERNAL. for a certain amount of time.
///
/// How about conflicts?
/// eg. we leave a group, our change isn't synced, user leaves and joins back from another client. then once our device comes online we will try to leave again and it will do something unexpected. We could see which to apply with the OG action time and compare it with joined at. 

