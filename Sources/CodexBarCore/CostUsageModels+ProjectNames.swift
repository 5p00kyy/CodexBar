import Foundation

extension CostUsageProjectBreakdown {
    func withName(_ name: String) -> Self {
        Self(
            name: name,
            path: self.path,
            totalTokens: self.totalTokens,
            totalCostUSD: self.totalCostUSD,
            daily: self.daily,
            modelBreakdowns: self.modelBreakdowns,
            sources: self.sources)
    }
}

extension CostUsageSessionBreakdown {
    func withProjectName(_ name: String) -> Self {
        var copy = Self(
            sessionID: self.sessionID,
            lastActivity: self.lastActivity,
            inputTokens: self.inputTokens,
            cachedInputTokens: self.cachedInputTokens,
            outputTokens: self.outputTokens,
            reasoningTokens: self.reasoningTokens,
            totalTokens: self.totalTokens,
            requestCount: self.requestCount,
            costUSD: self.costUSD,
            modelBreakdowns: self.modelBreakdowns,
            projectPath: self.projectPath,
            projectName: name,
            title: self.title)
        copy.workingDirectory = self.workingDirectory
        return copy
    }
}
