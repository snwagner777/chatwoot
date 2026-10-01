import { defineComponent, h, nextTick, ref } from 'vue';
import { mount } from '@vue/test-utils';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { operatorThemeForAccount, useOperatorTheme } from '../useOperatorTheme';
import { useAccount } from '../useAccount';

vi.mock('../useAccount', () => ({ useAccount: vi.fn() }));

afterEach(() => {
  delete document.documentElement.dataset.operatorTheme;
  vi.clearAllMocks();
});

describe('account-scoped operator theme', () => {
  it('ignores unsupported account theme values', () => {
    expect(operatorThemeForAccount(null)).toBe('neutral');
    expect(
      operatorThemeForAccount({
        custom_attributes: { operator_theme: 'untrusted-css' },
      })
    ).toBe('neutral');
    expect(
      operatorThemeForAccount({
        custom_attributes: { operator_theme: 'economyops' },
      })
    ).toBe('economyops');
  });

  it('resets on account switch, missing account data, and unmount', async () => {
    const currentAccount = ref({
      custom_attributes: { operator_theme: 'economyops' },
    });
    vi.mocked(useAccount).mockReturnValue({ currentAccount });
    const TestComponent = defineComponent({
      setup() {
        useOperatorTheme();
        return () => h('div');
      },
    });
    const wrapper = mount(TestComponent);
    expect(document.documentElement.dataset.operatorTheme).toBe('economyops');
    currentAccount.value = { custom_attributes: { operator_theme: 'unknown' } };
    await nextTick();
    expect(document.documentElement.dataset.operatorTheme).toBe('neutral');
    currentAccount.value = {
      custom_attributes: { operator_theme: 'economyops' },
    };
    await nextTick();
    expect(document.documentElement.dataset.operatorTheme).toBe('economyops');
    wrapper.unmount();
    expect(document.documentElement.dataset.operatorTheme).toBeUndefined();
  });
});
