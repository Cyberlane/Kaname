#if os(iOS)
/// Ephemeral state for the Phase 0 iPhone fixture. It intentionally remains in
/// the prototype target: no provider, account, queue, or approval is persisted
/// or contacted by this build.
struct IPhoneFixtureState {
    var isMacReachable = false
    var queuedCommands = PhoneQueuedCommand.fixtureItems
    var notificationRoute: PhoneNotificationRoute?
    var newDraftRoute: IPhoneNewDraftRoute?
    var approvalReceipt: String?
}
#endif
