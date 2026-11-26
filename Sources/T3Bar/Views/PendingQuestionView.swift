import SwiftUI

struct PendingQuestionView: View {
    let request: PendingUserRequest
    let isSubmitting: Bool
    let theme: T3Theme
    let onSubmit: ([String: String]) -> Void

    @State private var singleSelections: [String: String] = [:]
    @State private var multiSelections: [String: Set<String>] = [:]
    @State private var customTexts: [String: String] = [:]
    @State private var showCustomInput: Set<String> = []

    private var isSingleQuickQuestion: Bool {
        request.questions.count == 1
            && !(request.questions[0].multiSelect)
            && !request.questions[0].options.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(request.questions) { question in
                questionBlock(question)
            }

            if !isSingleQuickQuestion {
                HStack {
                    Spacer()
                    Button {
                        submitCollectedAnswers()
                    } label: {
                        HStack(spacing: 5) {
                            if isSubmitting {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Text(isSubmitting ? "Sending…" : "Send Answer")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .controlSize(.small)
                    .disabled(isSubmitting || !canSubmitAll)
                }
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.7)
        )
    }

    @ViewBuilder
    private func questionBlock(_ q: PendingUserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let header = q.header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.orange)
            }

            Text(q.question)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !q.options.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(q.options) { option in
                        optionButton(option, for: q)
                    }
                }
            }

            if q.options.isEmpty || showCustomInput.contains(q.id) {
                HStack(spacing: 6) {
                    TextField("Type your answer…", text: customTextBinding(for: q.id))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                        .disabled(isSubmitting)
                        .onSubmit {
                            if isSingleQuickQuestion || request.questions.count == 1 {
                                submitSingleCustom(for: q)
                            }
                        }

                    if isSingleQuickQuestion {
                        Button {
                            submitSingleCustom(for: q)
                        } label: {
                            if isSubmitting {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(theme.accent)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting || trimmedCustom(q.id).isEmpty)
                    }
                }
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        _ = showCustomInput.insert(q.id)
                    }
                } label: {
                    Text("Custom reply…")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }
        }
    }

    private func optionButton(_ option: PendingUserQuestionOption, for q: PendingUserQuestion) -> some View {
        let selected = isSelected(option, for: q)

        return Button {
            handleOptionTap(option, for: q)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                if q.multiSelect {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11.5))
                        .foregroundStyle(selected ? theme.accent : .secondary)
                        .padding(.top, 1)
                } else if !isSingleQuickQuestion {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(selected ? theme.accent : .secondary)
                        .padding(.top, 1)
                }

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 4)

                if isSingleQuickQuestion {
                    if isSubmitting && selected {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary.opacity(0.75))
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? theme.accent.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? theme.accent.opacity(0.5) : Color.primary.opacity(0.09), lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }

    private func isSelected(_ option: PendingUserQuestionOption, for q: PendingUserQuestion) -> Bool {
        if q.multiSelect {
            return multiSelections[q.id]?.contains(option.answerValue) == true
        }
        return singleSelections[q.id] == option.answerValue
    }

    private func handleOptionTap(_ option: PendingUserQuestionOption, for q: PendingUserQuestion) {
        if isSingleQuickQuestion {
            singleSelections[q.id] = option.answerValue
            onSubmit([q.id: option.answerValue])
            return
        }

        if q.multiSelect {
            var set = multiSelections[q.id] ?? []
            if set.contains(option.answerValue) {
                set.remove(option.answerValue)
            } else {
                set.insert(option.answerValue)
            }
            multiSelections[q.id] = set
        } else {
            singleSelections[q.id] = option.answerValue
        }
    }

    private func customTextBinding(for questionId: String) -> Binding<String> {
        Binding(
            get: { customTexts[questionId] ?? "" },
            set: { customTexts[questionId] = $0 }
        )
    }

    private func trimmedCustom(_ questionId: String) -> String {
        (customTexts[questionId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitSingleCustom(for q: PendingUserQuestion) {
        let text = trimmedCustom(q.id)
        guard !text.isEmpty else { return }
        onSubmit([q.id: text])
    }

    private var canSubmitAll: Bool {
        for q in request.questions {
            if resolvedAnswer(for: q) == nil {
                return false
            }
        }
        return !request.questions.isEmpty
    }

    private func resolvedAnswer(for q: PendingUserQuestion) -> String? {
        let custom = trimmedCustom(q.id)
        if q.multiSelect {
            var parts = q.options
                .map(\.answerValue)
                .filter { multiSelections[q.id]?.contains($0) == true }
            if !custom.isEmpty {
                parts.append(custom)
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        if !custom.isEmpty {
            return custom
        }
        return singleSelections[q.id]
    }

    private func submitCollectedAnswers() {
        var answers: [String: String] = [:]
        for q in request.questions {
            if let ans = resolvedAnswer(for: q) {
                answers[q.id] = ans
            }
        }
        guard !answers.isEmpty else { return }
        onSubmit(answers)
    }
}
