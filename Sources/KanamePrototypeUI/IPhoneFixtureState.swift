#if os(iOS)
/// Deterministic content used by domains that are not connected yet. Device
/// enrollment and reachability are owned separately by the production mobile
/// shell, so fixture state cannot claim transport authority.
struct IPhoneFixtureState {
    var notificationRoute: PhoneNotificationRoute?
    var newDraftRoute: IPhoneNewDraftRoute?
    var approvalReceipt: String?
}
#endif
