function Get-SparkZCodeOptionSpecs {
    param(
        [Parameter(Mandatory)][ValidateSet('glm','deepseek','qwen')][string]$ModelKey,
        [Parameter(Mandatory)][int]$MaxOutputTokens
    )

    # ZCode 3.18.2 uses the last configured value as the initial selection.
    $levels = switch ($ModelKey) {
        'glm' { 'disabled','low','max','high' }
        'deepseek' { 'disabled','low','medium','max','high' }
        'qwen' { 'disabled','low','medium','xhigh' }
    }
    @{
        reasoningLevel = @{
            values = @($levels)
            map = 'reasoningLevel == "disabled" ? {"chat_template_kwargs":{"enable_thinking":false}} : {"chat_template_kwargs":{"enable_thinking":true,"reasoning_effort":reasoningLevel}}'
        }
        maxOutputTokens = @{ max = $MaxOutputTokens; map = '{"max_tokens":maxOutputTokens}' }
    }
}
