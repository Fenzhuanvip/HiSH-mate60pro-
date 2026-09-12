export class PromptRecord {
  id: string;
  name: string;
  content: string;
  description: string;
  enabled: boolean;
  createdAt: number;
  updatedAt: number;

  constructor(
    id: string, name: string, content: string,
    description: string, enabled: boolean,
    createdAt: number, updatedAt: number
  ) {
    this.id = id;
    this.name = name;
    this.content = content;
    this.description = description;
    this.enabled = enabled;
    this.createdAt = createdAt;
    this.updatedAt = updatedAt;
  }

  static fromJSON(json: Record<string, Object>): PromptRecord {
    return new PromptRecord(
      (json.id as string) ?? '',
      (json.name as string) ?? '',
      (json.content as string) ?? '',
      (json.description as string) ?? '',
      (json.enabled as boolean) ?? false,
      (json.createdAt as number) ?? Date.now(),
      (json.updatedAt as number) ?? 0
    );
  }
}

export class PromptImportResult {
  prompt: PromptRecord;
  existingContent: string;

  constructor(prompt: PromptRecord, existingContent: string) {
    this.prompt = prompt;
    this.existingContent = existingContent;
  }
}
