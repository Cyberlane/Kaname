using System.Text.Json;
using System.Text.Json.Serialization;
using Cyberlane.KanameLink;

if (args.Length != 1)
{
    throw new InvalidOperationException("status_contract_path_required");
}

var options = new JsonSerializerOptions
{
    PropertyNameCaseInsensitive = false,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
};
var contract = JsonSerializer.Deserialize<StatusContract>(
    File.ReadAllText(Path.GetFullPath(args[0])),
    options
) ?? throw new InvalidOperationException("status_contract_invalid");

Ensure(contract.SchemaVersion == 1, "schema_version");
Ensure(contract.PrivacyClass == "synthetic-public", "privacy_class");
Ensure(
    contract.SemanticTones.SequenceEqual(
        Enum.GetValues<LinkSemanticTone>().Select(tone => tone.ContractValue())
    ),
    "semantic_tones"
);

foreach (var expected in contract.Connections)
{
    var status = LinkConnectionStatus.FromWire(expected.WireValue);
    AssertPresentation(
        status.KindKey,
        status.Presentation,
        expected,
        $"connection:{expected.WireValue}"
    );
}
foreach (var expected in contract.Discussions)
{
    var status = LinkDiscussionStatus.FromWire(expected.WireValue);
    AssertPresentation(
        status.KindKey,
        status.Presentation,
        expected,
        $"discussion:{expected.WireValue}"
    );
}
foreach (var expected in contract.Receipts)
{
    var status = LinkReceiptStatus.FromWire(expected.WireValue);
    AssertPresentation(
        status.KindKey,
        status.Presentation,
        expected,
        $"receipt:{expected.WireValue}"
    );
}
foreach (var expected in contract.Participants)
{
    var role = LinkParticipantRole.FromWire(expected.WireValue);
    AssertPresentation(
        role.KindKey,
        role.Presentation,
        new StatusContractEntry(
            expected.WireValue,
            expected.Kind,
            expected.Label,
            expected.Tone,
            expected.AccessibilityLabel
        ),
        $"participant:{expected.WireValue}"
    );
    Ensure(
        role.IsLocalPrincipal == expected.IsLocalPrincipal,
        $"participant-local:{expected.WireValue}"
    );
}
foreach (var expected in contract.HostVerifications)
{
    var state = LinkHostVerificationState.FromVerified(expected.Verified);
    Ensure(state.KindKey == expected.Kind, $"host-verification:{expected.Kind}:kind");
    Ensure(
        state.Presentation.Tone.ContractValue() == expected.Tone,
        $"host-verification:{expected.Kind}:tone"
    );
    Ensure(
        state.Presentation.AccessibilityLabel == expected.AccessibilityLabel,
        $"host-verification:{expected.Kind}:accessibility"
    );
}

var unknownConnection = LinkConnectionStatus.FromWire("future-connection");
Ensure(unknownConnection.Kind == LinkConnectionKind.Unrecognized, "unknown_connection_kind");
Ensure(unknownConnection.Presentation.Tone == LinkSemanticTone.Blocked, "unknown_connection_tone");
Ensure(!unknownConnection.Capabilities.CanRequestEnrollment, "unknown_connection_enrollment");
Ensure(!unknownConnection.Capabilities.CanQueueMessage, "unknown_connection_queue");
Ensure(
    LinkDiscussionStatus.FromWire("future-discussion").Presentation.Tone == LinkSemanticTone.Warning,
    "unknown_discussion"
);
Ensure(
    LinkReceiptStatus.FromWire("future-receipt").Presentation.Label == "Outcome uncertain",
    "unknown_receipt"
);
Ensure(
    !LinkParticipantRole.FromWire("future-participant").IsLocalPrincipal,
    "unknown_participant"
);
Ensure(
    LinkConnectionStatus.FromWire("hostOffline").Capabilities.CanQueueMessage,
    "windows_offline_queue_policy"
);

Console.WriteLine("Kaname Link Windows status contract passed.");

static void AssertPresentation(
    string kind,
    LinkStatusPresentation presentation,
    StatusContractEntry expected,
    string scope
)
{
    Ensure(kind == expected.Kind, $"{scope}:kind");
    Ensure(presentation.Label == expected.Label, $"{scope}:label");
    Ensure(presentation.Tone.ContractValue() == expected.Tone, $"{scope}:tone");
    Ensure(
        presentation.AccessibilityLabel == expected.AccessibilityLabel,
        $"{scope}:accessibility"
    );
}

static void Ensure(bool condition, string field)
{
    if (!condition)
    {
        throw new InvalidOperationException($"status_contract_mismatch:{field}");
    }
}

internal sealed record StatusContract(
    [property: JsonPropertyName("schemaVersion")] int SchemaVersion,
    [property: JsonPropertyName("privacyClass")] string PrivacyClass,
    [property: JsonPropertyName("semanticTones")] IReadOnlyList<string> SemanticTones,
    [property: JsonPropertyName("connections")] IReadOnlyList<StatusContractEntry> Connections,
    [property: JsonPropertyName("discussions")] IReadOnlyList<StatusContractEntry> Discussions,
    [property: JsonPropertyName("receipts")] IReadOnlyList<StatusContractEntry> Receipts,
    [property: JsonPropertyName("participants")] IReadOnlyList<ParticipantContractEntry> Participants,
    [property: JsonPropertyName("hostVerifications")]
    IReadOnlyList<HostVerificationContractEntry> HostVerifications
);

internal record StatusContractEntry(
    [property: JsonPropertyName("wireValue")] string WireValue,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("label")] string Label,
    [property: JsonPropertyName("tone")] string Tone,
    [property: JsonPropertyName("accessibilityLabel")] string AccessibilityLabel
);

internal sealed record ParticipantContractEntry(
    [property: JsonPropertyName("wireValue")] string WireValue,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("label")] string Label,
    [property: JsonPropertyName("tone")] string Tone,
    [property: JsonPropertyName("accessibilityLabel")] string AccessibilityLabel,
    [property: JsonPropertyName("isLocalPrincipal")] bool IsLocalPrincipal
);

internal sealed record HostVerificationContractEntry(
    [property: JsonPropertyName("verified")] bool Verified,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("tone")] string Tone,
    [property: JsonPropertyName("accessibilityLabel")] string AccessibilityLabel
);
