import Foundation

/// The wire objects the exchange reads (PROTOCOL §6.1, §6.4): accepted entries, decisions, slots,
/// records and commits, decoded from strictly parsed protocol JSON. Unknown members are ignored; missing required
/// members make the object invalid (`ServerWireError`).
public enum ServerWireError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String)
    public var description: String { if case .invalid(let detail) = self { "invalid wire object: \(detail)" } else { "" } }
}

/// One record of the server's derived state (`{entity, id, field_group, value | tombstone, provenance}`).
struct ServerRecord: Sendable, Equatable {
    var entity: String
    var id: String
    var fieldGroup: String
    /// Nil for a tombstone.
    var value: ContractJSON?
    var provenance: [String]

    var key: ServerRecordKey { ServerRecordKey(entity: entity, id: id, fieldGroup: fieldGroup) }

    init(entity: String, id: String, fieldGroup: String, value: ContractJSON?, provenance: [String] = []) {
        self.entity = entity; self.id = id; self.fieldGroup = fieldGroup; self.value = value; self.provenance = provenance
    }

    init(_ json: ContractJSON) throws {
        guard let entity = json["entity"]?.stringValue, let id = json["id"]?.stringValue,
              let group = json["field_group"]?.stringValue else { throw ServerWireError.invalid("record") }
        self.entity = entity; self.id = id; fieldGroup = group
        if json["tombstone"]?.boolValue == true { value = nil }
        else {
            guard let value = json["value"], value.objectValue != nil else { throw ServerWireError.invalid("record value") }
            self.value = value
        }
        provenance = json["provenance"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

struct ServerRecordKey: Hashable, Sendable, Comparable {
    var entity: String
    var id: String
    var fieldGroup: String

    static func < (lhs: ServerRecordKey, rhs: ServerRecordKey) -> Bool {
        [lhs.entity, lhs.id, lhs.fieldGroup].lexicographicallyPrecedes([rhs.entity, rhs.id, rhs.fieldGroup]) {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
    }
}

/// An accepted entry `{fact, receipt}`.
struct ServerAcceptedEntry: Sendable {
    var fact: ContractJSON
    var receipt: ContractJSON
    var opID: String
    var contentHash: String
    var outcome: String
    var reason: String?
    var normalizedTime: Int64
    var epoch: Int64
    var seq: Int64
    var index: Int64
    var type: String
    var authorID: String?

    init(_ json: ContractJSON) throws {
        guard let fact = json["fact"], let receipt = json["receipt"], fact.objectValue != nil,
              let op = receipt["op_id"]?.stringValue, let hash = receipt["content_hash"]?.stringValue,
              let outcome = receipt["outcome"]?.stringValue, let time = receipt["normalized_time"]?.integerValue,
              let epoch = receipt["epoch"]?.integerValue, let seq = receipt["seq"]?.integerValue else {
            throw ServerWireError.invalid("accepted entry")
        }
        guard fact["op_id"]?.stringValue == op else { throw ServerWireError.invalid("accepted entry op_id") }
        self.fact = fact; self.receipt = receipt; opID = op; contentHash = hash; self.outcome = outcome
        reason = receipt["reason"]?.stringValue; normalizedTime = time; self.epoch = epoch; self.seq = seq
        index = receipt["index"]?.integerValue ?? 0
        type = fact["type"]?.stringValue ?? ""
        authorID = fact["author_id"]?.stringValue
    }

    /// Rejected facts are archived evidence, never causal nodes (PROTOCOL §6.4).
    var isCausalNode: Bool { outcome != "rejected" }
    var dependencies: [String] { fact["dependencies"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    var payload: ContractJSON { fact["payload"] ?? .null }
}

/// A server decision (PROTOCOL §6.1).
struct ServerDecision: Sendable {
    var json: ContractJSON
    var decisionID: String
    var type: String
    var subject: String
    var epoch: Int64
    var seq: Int64
    var index: Int64
    var normalizedTime: Int64
    var dependencies: [String]
    var result: ContractJSON

    init(_ json: ContractJSON) throws {
        guard let id = json["decision_id"]?.stringValue, let type = json["decision_type"]?.stringValue,
              let subject = json["subject"]?.stringValue, let epoch = json["epoch"]?.integerValue,
              let seq = json["seq"]?.integerValue, let time = json["normalized_time"]?.integerValue else {
            throw ServerWireError.invalid("decision")
        }
        self.json = json; decisionID = id; self.type = type; self.subject = subject; self.epoch = epoch; self.seq = seq
        index = json["index"]?.integerValue ?? 0; normalizedTime = time
        dependencies = json["dependencies"]?.arrayValue?.compactMap(\.stringValue) ?? []
        result = json["result"] ?? .null
    }
}

/// A consumed transport slot (`{install_id, install_seq, op_id, content_hash, result}`).
struct ServerSlot: Sendable, Equatable {
    var installID: String
    var installSeq: Int64
    var opID: String
    var contentHash: String?
    var result: String

    init(_ json: ContractJSON) throws {
        guard let install = json["install_id"]?.stringValue, let seq = json["install_seq"]?.integerValue,
              let op = json["op_id"]?.stringValue else { throw ServerWireError.invalid("slot") }
        installID = install; installSeq = seq; opID = op
        contentHash = json["content_hash"]?.stringValue
        result = json["result"]?.stringValue ?? "accepted"
    }
}

/// One change-log commit (PROTOCOL §6.1).
struct ServerCommit: Sendable {
    var epoch: Int64
    var seq: Int64
    var accepted: [ServerAcceptedEntry]
    var decisions: [ServerDecision]
    var slots: [ServerSlot]
    var records: [ServerRecord]

    init(_ json: ContractJSON) throws {
        guard let epoch = json["epoch"]?.integerValue, let seq = json["seq"]?.integerValue else {
            throw ServerWireError.invalid("commit")
        }
        self.epoch = epoch; self.seq = seq
        accepted = try (json["accepted"]?.arrayValue ?? []).map(ServerAcceptedEntry.init)
        decisions = try (json["decisions"]?.arrayValue ?? []).map(ServerDecision.init)
        slots = try (json["slots"]?.arrayValue ?? []).map(ServerSlot.init)
        records = try (json["records"]?.arrayValue ?? []).map(ServerRecord.init)
    }

    init(epoch: Int64, seq: Int64, accepted: [ServerAcceptedEntry] = [], decisions: [ServerDecision] = [],
         slots: [ServerSlot] = [], records: [ServerRecord] = []) {
        self.epoch = epoch; self.seq = seq; self.accepted = accepted; self.decisions = decisions
        self.slots = slots; self.records = records
    }
}

extension ContractJSON {
    /// The canonical JSON of a value as a string, for `ntp_*` columns that hold JSON text.
    var canonicalText: String { (try? canonicalString()) ?? "null" }
}
