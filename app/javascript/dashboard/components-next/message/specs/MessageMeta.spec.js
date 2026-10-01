import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import { describe, expect, it, vi } from 'vitest';
import MessageMeta from '../MessageMeta.vue';
import MessageStatus from '../MessageStatus.vue';
import { useMessageContext } from '../provider';

vi.mock('../provider', () => ({ useMessageContext: vi.fn() }));
vi.mock('dashboard/composables/useInbox', () => ({
  useInbox: () =>
    Object.fromEntries(
      [
        'isAFacebookInbox',
        'isALineChannel',
        'isAPIInbox',
        'isASmsInbox',
        'isATelegramChannel',
        'isATwilioChannel',
        'isAWebWidgetInbox',
        'isAWhatsAppChannel',
        'isAnEmailChannel',
        'isAnInstagramChannel',
        'isATiktokChannel',
      ].map(key => [key, ref(key === 'isAPIInbox')])
    ),
}));
vi.mock('shared/composables/useExactTimestamp', () => ({
  useExactTimestamp: () => () => 'timestamp',
}));

describe('API provider message delivery status', () => {
  it.each([
    ['pending', 'progress'],
    ['delivery_unknown', 'delivery_unknown'],
    ['sent', 'sent'],
    ['delivered', 'delivered'],
  ])('renders %s as %s', (status, expected) => {
    vi.mocked(useMessageContext).mockReturnValue({
      status: ref(status),
      isPrivate: ref(false),
      createdAt: ref(1700000000),
      sourceId: ref(null),
      messageType: ref(1),
      contentAttributes: ref({}),
    });
    const wrapper = mount(MessageMeta, {
      global: { stubs: { MessageStatus: true, Icon: true } },
    });
    expect(wrapper.findComponent(MessageStatus).props('status')).toBe(expected);
  });
});
