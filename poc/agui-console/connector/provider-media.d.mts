export interface ProviderPromptReference {
  cursor: string;
  pageCursor?: string;
  itemCount: number;
}
export interface ProviderMedia {
  kind: 'image' | 'audio';
  mime?: string;
  preview?: string;
  reference?: string;
}
export function providerPromptReference(activity: unknown): ProviderPromptReference | undefined;
export function providerPromptMedia(record: unknown): ProviderMedia[];
export function providerSupplementalMedia(record: unknown): ProviderMedia | undefined;
export function selectedProviderMedia(page: unknown, reference: ProviderPromptReference): ProviderMedia[];
