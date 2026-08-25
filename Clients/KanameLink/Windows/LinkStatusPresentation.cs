namespace Cyberlane.KanameLink;

internal enum LinkSemanticTone
{
    Neutral,
    Informational,
    Active,
    Attention,
    Success,
    Warning,
    Danger,
    Blocked,
    External,
}

internal static class LinkSemanticToneExtensions
{
    public static string ContractValue(this LinkSemanticTone tone) => tone switch
    {
        LinkSemanticTone.Neutral => "neutral",
        LinkSemanticTone.Informational => "informational",
        LinkSemanticTone.Active => "active",
        LinkSemanticTone.Attention => "attention",
        LinkSemanticTone.Success => "success",
        LinkSemanticTone.Warning => "warning",
        LinkSemanticTone.Danger => "danger",
        LinkSemanticTone.Blocked => "blocked",
        LinkSemanticTone.External => "external",
        _ => throw new ArgumentOutOfRangeException(nameof(tone)),
    };

    public static string BrushResourceKey(this LinkSemanticTone tone) => tone switch
    {
        LinkSemanticTone.Neutral => "KanameTextSecondaryBrush",
        LinkSemanticTone.Informational => "KanameAccentStrongBrush",
        LinkSemanticTone.Active => "KanameActiveBrush",
        LinkSemanticTone.Attention => "KanameWarningBrush",
        LinkSemanticTone.Success => "KanameSuccessBrush",
        LinkSemanticTone.Warning => "KanameWarningBrush",
        LinkSemanticTone.Danger => "KanameDangerBrush",
        LinkSemanticTone.Blocked => "KanameBlockedBrush",
        LinkSemanticTone.External => "KanameExternalBrush",
        _ => throw new ArgumentOutOfRangeException(nameof(tone)),
    };

    public static string IconResourceKey(this LinkSemanticTone tone) => tone switch
    {
        LinkSemanticTone.Neutral => "KanameStatusNeutralIcon",
        LinkSemanticTone.Informational => "KanameStatusInformationalIcon",
        LinkSemanticTone.Active => "KanameStatusActiveIcon",
        LinkSemanticTone.Attention => "KanameStatusAttentionIcon",
        LinkSemanticTone.Success => "KanameStatusSuccessIcon",
        LinkSemanticTone.Warning => "KanameStatusWarningIcon",
        LinkSemanticTone.Danger => "KanameStatusDangerIcon",
        LinkSemanticTone.Blocked => "KanameStatusBlockedIcon",
        LinkSemanticTone.External => "KanameStatusExternalIcon",
        _ => throw new ArgumentOutOfRangeException(nameof(tone)),
    };
}

internal sealed record LinkStatusPresentation(
    string Label,
    LinkSemanticTone Tone,
    string AccessibilityLabel
);

internal sealed record LinkConnectionCapabilities(
    bool CanRequestEnrollment,
    bool CanQueueMessage
);

internal enum LinkConnectionKind
{
    HostOnline,
    Connecting,
    HostOffline,
    EnrollmentRequired,
    Revoked,
    Unrecognized,
}

internal sealed record LinkConnectionStatus(
    LinkConnectionKind Kind,
    string? UnrecognizedValue = null
)
{
    public static LinkConnectionStatus FromWire(string value) => value switch
    {
        "hostOnline" => new(LinkConnectionKind.HostOnline),
        "connecting" => new(LinkConnectionKind.Connecting),
        "hostOffline" => new(LinkConnectionKind.HostOffline),
        "enrollmentRequired" => new(LinkConnectionKind.EnrollmentRequired),
        "revoked" => new(LinkConnectionKind.Revoked),
        _ => new(LinkConnectionKind.Unrecognized, value),
    };

    public string KindKey => Kind switch
    {
        LinkConnectionKind.HostOnline => "hostOnline",
        LinkConnectionKind.Connecting => "connecting",
        LinkConnectionKind.HostOffline => "hostOffline",
        LinkConnectionKind.EnrollmentRequired => "enrollmentRequired",
        LinkConnectionKind.Revoked => "revoked",
        LinkConnectionKind.Unrecognized => "unrecognized",
        _ => throw new ArgumentOutOfRangeException(nameof(Kind)),
    };

    public LinkStatusPresentation Presentation => Kind switch
    {
        LinkConnectionKind.HostOnline => new(
            "Host online",
            LinkSemanticTone.Success,
            "Connection status: Host online"
        ),
        LinkConnectionKind.Connecting => new(
            "Connecting",
            LinkSemanticTone.Active,
            "Connection status: Connecting"
        ),
        LinkConnectionKind.HostOffline => new(
            "Host offline",
            LinkSemanticTone.Warning,
            "Connection status: Host offline"
        ),
        LinkConnectionKind.EnrollmentRequired => new(
            "Enrollment required",
            LinkSemanticTone.External,
            "Connection status: Enrollment required"
        ),
        LinkConnectionKind.Revoked => new(
            "Access revoked",
            LinkSemanticTone.Blocked,
            "Connection status: Access revoked"
        ),
        LinkConnectionKind.Unrecognized => new(
            "Connection state unavailable",
            LinkSemanticTone.Blocked,
            "Connection status: Connection state unavailable"
        ),
        _ => throw new ArgumentOutOfRangeException(nameof(Kind)),
    };

    public LinkConnectionCapabilities Capabilities => Kind switch
    {
        LinkConnectionKind.HostOnline or LinkConnectionKind.HostOffline => new(
            false,
            // Windows already permits durable local queueing while the host is offline.
            true
        ),
        LinkConnectionKind.EnrollmentRequired => new(true, false),
        LinkConnectionKind.Connecting or LinkConnectionKind.Revoked or LinkConnectionKind.Unrecognized => new(false, false),
        _ => throw new ArgumentOutOfRangeException(nameof(Kind)),
    };
}

internal enum LinkDiscussionKind
{
    ActionRequired,
    WaitingForHost,
    UpToDate,
    Delivered,
    Unrecognized,
}

internal sealed record LinkDiscussionStatus(
    LinkDiscussionKind Kind,
    string? UnrecognizedValue = null
)
{
    public static LinkDiscussionStatus FromWire(string value) => value switch
    {
        "Waiting for you" => new(LinkDiscussionKind.ActionRequired),
        "Waiting for host" => new(LinkDiscussionKind.WaitingForHost),
        "Up to date" => new(LinkDiscussionKind.UpToDate),
        "Delivered" => new(LinkDiscussionKind.Delivered),
        _ => new(LinkDiscussionKind.Unrecognized, value),
    };

    public string KindKey => Kind switch
    {
        LinkDiscussionKind.ActionRequired => "actionRequired",
        LinkDiscussionKind.WaitingForHost => "waitingForHost",
        LinkDiscussionKind.UpToDate => "upToDate",
        LinkDiscussionKind.Delivered => "delivered",
        LinkDiscussionKind.Unrecognized => "unrecognized",
        _ => throw new ArgumentOutOfRangeException(nameof(Kind)),
    };

    public LinkStatusPresentation Presentation => Kind switch
    {
        LinkDiscussionKind.ActionRequired => new(
            "Waiting for you",
            LinkSemanticTone.Attention,
            "Discussion status: Waiting for you. Action required."
        ),
        LinkDiscussionKind.WaitingForHost => new(
            "Waiting for host",
            LinkSemanticTone.Active,
            "Discussion status: Waiting for host"
        ),
        LinkDiscussionKind.UpToDate => new(
            "Up to date",
            LinkSemanticTone.Success,
            "Discussion status: Up to date"
        ),
        LinkDiscussionKind.Delivered => new(
            "Delivered",
            LinkSemanticTone.Success,
            "Discussion status: Delivered"
        ),
        LinkDiscussionKind.Unrecognized => new(
            "Outcome uncertain",
            LinkSemanticTone.Warning,
            "Discussion status: Outcome uncertain"
        ),
        _ => throw new ArgumentOutOfRangeException(nameof(Kind)),
    };
}

internal enum LinkReceiptKind
{
    LocalStored,
    Queued,
    GatewayAccepted,
    Published,
    Delivered,
    Failed,
    OutcomeUncertain,
    Unrecognized,
}

internal sealed record LinkReceiptStatus(
    LinkReceiptKind Kind,
    string? UnrecognizedValue = null
)
{
    public static LinkReceiptStatus FromWire(string value) => value switch
    {
        "Stored locally" => new(LinkReceiptKind.LocalStored),
        "Queued locally" or "Queued on this device" => new(LinkReceiptKind.Queued),
        "Received by host" => new(LinkReceiptKind.GatewayAccepted),
        "Published by host" or "Published result" => new(LinkReceiptKind.Published),
        "Delivered" => new(LinkReceiptKind.Delivered),
        "Observed failure" => new(LinkReceiptKind.Failed),
        "Outcome uncertain" => new(LinkReceiptKind.OutcomeUncertain),
        _ => new(LinkReceiptKind.Unrecognized, value),
    };

    public string KindKey => Kind switch
    {
        LinkReceiptKind.LocalStored => "localStored",
        LinkReceiptKind.Queued => "queued",
        LinkReceiptKind.GatewayAccepted => "gatewayAccepted",
        LinkReceiptKind.Published => "published",
        LinkReceiptKind.Delivered => "delivered",
        LinkReceiptKind.Failed => "failed",
        LinkReceiptKind.OutcomeUncertain => "outcomeUncertain",
        LinkReceiptKind.Unrecognized => "unrecognized",
        _ => throw new ArgumentOutOfRangeException(nameof(Kind)),
    };

    public LinkStatusPresentation Presentation => Kind switch
    {
        LinkReceiptKind.LocalStored => new(
            "Stored locally",
            LinkSemanticTone.Informational,
            "Message status: Stored locally"
        ),
        LinkReceiptKind.Queued => new(
            "Queued locally",
            LinkSemanticTone.Active,
            "Message status: Queued locally"
        ),
        LinkReceiptKind.GatewayAccepted => new(
            "Received by host",
            LinkSemanticTone.Informational,
            "Message status: Received by host"
        ),
        LinkReceiptKind.Published => new(
            "Published by host",
            LinkSemanticTone.External,
            "Message status: Published by host"
        ),
        LinkReceiptKind.Delivered => new(
            "Delivered",
            LinkSemanticTone.Success,
            "Message status: Delivered"
        ),
        LinkReceiptKind.Failed => new(
            "Observed failure",
            LinkSemanticTone.Danger,
            "Message status: Observed failure"
        ),
        LinkReceiptKind.OutcomeUncertain or LinkReceiptKind.Unrecognized => new(
            "Outcome uncertain",
            LinkSemanticTone.Warning,
            "Message status: Outcome uncertain"
        ),
        _ => throw new ArgumentOutOfRangeException(nameof(Kind)),
    };
}

internal enum LinkParticipantKind
{
    Host,
    Collaborator,
    Unrecognized,
}

internal sealed record LinkParticipantRole(
    LinkParticipantKind Kind,
    string? UnrecognizedValue = null
)
{
    public static LinkParticipantRole FromWire(string value) => value switch
    {
        "host" => new(LinkParticipantKind.Host),
        "collaborator" => new(LinkParticipantKind.Collaborator),
        _ => new(LinkParticipantKind.Unrecognized, value),
    };

    public string KindKey => Kind switch
    {
        LinkParticipantKind.Host => "host",
        LinkParticipantKind.Collaborator => "collaborator",
        LinkParticipantKind.Unrecognized => "unrecognized",
        _ => throw new ArgumentOutOfRangeException(nameof(Kind)),
    };

    public bool IsLocalPrincipal => Kind == LinkParticipantKind.Collaborator;

    public LinkStatusPresentation Presentation => Kind switch
    {
        LinkParticipantKind.Host => new("Host", LinkSemanticTone.Informational, "Participant: Host"),
        LinkParticipantKind.Collaborator => new(
            "External collaborator",
            LinkSemanticTone.External,
            "Participant: External collaborator"
        ),
        LinkParticipantKind.Unrecognized => new(
            "External participant",
            LinkSemanticTone.Blocked,
            "Participant: Unrecognized external participant"
        ),
        _ => throw new ArgumentOutOfRangeException(nameof(Kind)),
    };
}

internal enum LinkHostVerificationKind
{
    Verified,
    ApprovalPending,
}

internal sealed record LinkHostVerificationState(LinkHostVerificationKind Kind)
{
    public static LinkHostVerificationState FromVerified(bool verified) => new(
        verified ? LinkHostVerificationKind.Verified : LinkHostVerificationKind.ApprovalPending
    );

    public string KindKey => Kind switch
    {
        LinkHostVerificationKind.Verified => "verified",
        LinkHostVerificationKind.ApprovalPending => "approvalPending",
        _ => throw new ArgumentOutOfRangeException(nameof(Kind)),
    };

    public LinkStatusPresentation Presentation => Kind switch
    {
        LinkHostVerificationKind.Verified => new(
            "Verified host",
            LinkSemanticTone.Success,
            "Host verification: Verified"
        ),
        LinkHostVerificationKind.ApprovalPending => new(
            "Approval pending",
            LinkSemanticTone.Attention,
            "Host verification: Approval pending"
        ),
        _ => throw new ArgumentOutOfRangeException(nameof(Kind)),
    };
}
