function Get-SparkOpenCodeThinkingVariants {
    param([Parameter(Mandatory)][ValidateSet('glm','deepseek','qwen')][string]$ModelKey)

    $levels = @{
        glm = @('low','high','max')
        deepseek = @('low','medium','high','max')
        qwen = @('low','medium','xhigh')
    }
    $variants = [ordered]@{
        off = @{reasoningEffort='none';chat_template_kwargs=@{enable_thinking=$false}}
    }
    foreach ($effort in $levels[$ModelKey]) {
        $variants[$effort] = @{reasoningEffort=$effort;chat_template_kwargs=@{enable_thinking=$true}}
    }
    # OpenCode merges custom variants with automatic OpenAI-compatible levels.
    foreach ($effort in @('low','medium','high','max')) {
        if (!$variants.Contains($effort)) {
            $variants[$effort] = @{disabled=$true}
        }
    }
    return $variants
}
