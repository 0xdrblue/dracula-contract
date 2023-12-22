// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Owned} from "solmate/auth/Owned.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";

import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {FlashLoanReceiverBase} from "aave-v3-core/contracts/flashloan/base/FlashLoanReceiverBase.sol";
import {IPoolAddressesProvider} from "aave-v3-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {DataTypes} from "lib/aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {ICreditDelegationToken} from "lib/aave-v3-core/contracts/interfaces/ICreditDelegationToken.sol";

/// @title Dracula
/// @author Vampyre Finance
/// @dev Contract to perform a vampire attack on Aave, migrating positions from Aave to Vampyre
contract Dracula is Owned, FlashLoanReceiverBase {
    using SafeTransferLib for ERC20;

    /// ===============================================================
    /// Types
    /// ===============================================================

    struct PermitInput {
        ERC20 aToken;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct CreditDelegationInput {
        ICreditDelegationToken debtToken;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct RepayInput {
        address asset;
        uint256 amount;
        uint256 rateMode;
    }

    struct RepaySimpleInput {
        address asset;
        uint256 rateMode;
    }

    struct EmergencyTransferInput {
        ERC20 asset;
        uint256 amount;
        address to;
    }

    /// ===============================================================
    /// Events
    /// ===============================================================

    event DebtRepayed(address indexed user, RepayInput[] indexed debts);

    /// ===============================================================
    /// Errors
    /// ===============================================================

    error OnlyVampPoolAllowed();
    error OnlyInitiatedByDraculaContrtact();
    error InvalidOrNotCachedAsset(address asset, address aToken);

    /// ===============================================================
    /// Storage
    /// ===============================================================

    /// @notice The Victim pool (Aave)
    IPool public immutable aavePool;

    /// @notice The Preditor pool (Vampyre)
    IPool public immutable vampPool;

    /// @notice The deposit token cache
    mapping(address => ERC20) public aTokens;

    /// @notice The variable debt token cache
    mapping(address => ERC20) public vTokens;

    /// @notice The stable debt Cache
    mapping(address => ERC20) public sTokens;

    /// ===============================================================
    /// Initialization
    /// ===============================================================

    /// @param _vampyreAddressesProvider PoolAddressesProvider for Vampyre
    /// @param _aavePool The Victim pool (Aave)
    /// @param _vampPool The Preditor pool (Vampyre)
    constructor(IPoolAddressesProvider _vampyreAddressesProvider, IPool _aavePool, IPool _vampPool)
        Owned(msg.sender)
        FlashLoanReceiverBase(_vampyreAddressesProvider)
    {
        aavePool = _aavePool;
        vampPool = _vampPool;
        cacheATokens();
    }

    function cacheATokens() public {
        DataTypes.ReserveData memory reserveData;
        address[] memory reserves = aavePool.getReservesList();
        for (uint256 i = 0; i < reserves.length; i++) {
            if (address(aTokens[reserves[i]]) == address(0)) {
                reserveData = aavePool.getReserveData(reserves[i]);
                aTokens[reserves[i]] = ERC20(reserveData.aTokenAddress);
                vTokens[reserves[i]] = ERC20(reserveData.variableDebtTokenAddress);
                sTokens[reserves[i]] = ERC20(reserveData.stableDebtTokenAddress);

                ERC20(reserves[i]).safeApprove(address(aavePool), type(uint256).max);
                ERC20(reserves[i]).safeApprove(address(vampPool), type(uint256).max);
            }
        }
    }

    /// ===============================================================
    /// Meat and Bones
    /// ===============================================================

    /// @notice Main entry point to the attack. Migrating whole amount of specified assets
    /// @param assetsToVamp list of assets to migrate
    /// @param assetsToRepay list of assets to be repayed
    /// @param permits list of EIP712 permits, can be empty, if approvals provided in advance
    /// @param creditDelegationPermits ist of EIP712 signatures (credit delegations) for v3 variable debt token
    function feedOnTheGhost(
        address[] memory assetsToVamp,
        RepaySimpleInput[] memory assetsToRepay,
        PermitInput[] memory permits,
        CreditDelegationInput[] memory creditDelegationPermits
    ) external {
        for (uint256 i = 0; i < permits.length; i++) {
            permits[i].aToken.permit(
                msg.sender,
                address(this),
                permits[i].value,
                permits[i].deadline,
                permits[i].v,
                permits[i].r,
                permits[i].s
            );
        }

        if (assetsToRepay.length == 0) {
            _vampNoBorrow(msg.sender, assetsToVamp);
        } else {
            for (uint256 i = 0; i < creditDelegationPermits.length; i++) {
                creditDelegationPermits[i].debtToken.delegationWithSig(
                    msg.sender,
                    address(this),
                    creditDelegationPermits[i].value,
                    creditDelegationPermits[i].deadline,
                    creditDelegationPermits[i].v,
                    creditDelegationPermits[i].r,
                    creditDelegationPermits[i].s
                );
            }

            (
                RepayInput[] memory debtToRepayWithAmounts,
                address[] memory assetsToFlash,
                uint256[] memory amountsToFlash,
                uint256[] memory interestRatesToFlash
            ) = _getFlashloanParams(assetsToRepay);

            vampPool.flashLoan(
                address(this),
                assetsToFlash,
                amountsToFlash,
                interestRatesToFlash,
                msg.sender,
                abi.encode(assetsToVamp, debtToRepayWithAmounts, msg.sender),
                0
            );
        }
    }

    function _vampNoBorrow(address user, address[] memory assets) internal {
        address asset;
        ERC20 aToken;
        uint256 aTokenAmountToVamp;
        uint256 aTokenBalanceAfterReceiving;

        for (uint256 i = 0; i < assets.length; i++) {
            asset = assets[i];
            aToken = aTokens[asset];

            if (asset == address(0) || address(aToken) == address(0)) {
                revert InvalidOrNotCachedAsset({asset: asset, aToken: address(aToken)});
            }

            aTokenAmountToVamp = aToken.balanceOf(user);
            aToken.safeTransferFrom(user, address(this), aTokenAmountToVamp);

            // this part of logic needed because of the possible 1-3 wei imprecision after aToken transfer, for example on stETH
            aTokenBalanceAfterReceiving = aToken.balanceOf(address(this));
            if (
                aTokenAmountToVamp != aTokenBalanceAfterReceiving
                    && aTokenBalanceAfterReceiving <= aTokenAmountToVamp + 2
            ) {
                aTokenAmountToVamp = aTokenBalanceAfterReceiving;
            }

            uint256 withdrawn = aavePool.withdraw(asset, aTokenAmountToVamp, address(this));

            vampPool.supply(asset, withdrawn, user, 0);
        }
    }

    function _getFlashloanParams(RepaySimpleInput[] memory debtToRepay)
        internal
        view
        returns (RepayInput[] memory, address[] memory, uint256[] memory, uint256[] memory)
    {
        RepayInput[] memory debtToRepayWithAmounts = new RepayInput[](debtToRepay.length);

        uint256 numberOfAssetsToFlash;
        address[] memory assetsToFlash = new address[](debtToRepay.length);
        uint256[] memory amountsToFlash = new uint256[](debtToRepay.length);
        uint256[] memory interestRatesToFlash = new uint256[](debtToRepay.length);

        for (uint256 i = 0; i < debtToRepay.length; i++) {
            ERC20 debtToken =
                debtToRepay[i].rateMode == 2 ? vTokens[debtToRepay[i].asset] : sTokens[debtToRepay[i].asset];
            require(address(debtToken) != address(0), "THIS_TYPE_OF_DEBT_NOT_SET");

            debtToRepayWithAmounts[i] = RepayInput({
                asset: debtToRepay[i].asset,
                amount: debtToken.balanceOf(msg.sender),
                rateMode: debtToRepay[i].rateMode
            });

            bool amountIncludedIntoFlash;

            // if asset was also borrowed in another mode - add values
            for (uint256 j = 0; j < numberOfAssetsToFlash; j++) {
                if (assetsToFlash[j] == debtToRepay[i].asset) {
                    amountsToFlash[j] += debtToRepayWithAmounts[i].amount;
                    amountIncludedIntoFlash = true;
                    break;
                }
            }

            // if this is the first ocurance of the asset add it
            if (!amountIncludedIntoFlash) {
                assetsToFlash[numberOfAssetsToFlash] = debtToRepayWithAmounts[i].asset;
                amountsToFlash[numberOfAssetsToFlash] = debtToRepayWithAmounts[i].amount;
                interestRatesToFlash[numberOfAssetsToFlash] = 2; // @dev variable debt

                ++numberOfAssetsToFlash;
            }
        }

        // we do not know the length in advance, so we init arrays with the maximum possible length
        // and then squeeze the array using mstore
        assembly {
            mstore(assetsToFlash, numberOfAssetsToFlash)
            mstore(amountsToFlash, numberOfAssetsToFlash)
            mstore(interestRatesToFlash, numberOfAssetsToFlash)
        }

        return (debtToRepayWithAmounts, assetsToFlash, amountsToFlash, interestRatesToFlash);
    }

    function executeOperation(
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        if (msg.sender != address(vampPool)) revert OnlyVampPoolAllowed();
        if (initiator != address(this)) revert OnlyInitiatedByDraculaContrtact();

        // decode params
        (address[] memory assetsToMigrate, RepayInput[] memory debtToRepay, address user) =
            abi.decode(params, (address[], RepayInput[], address));

        // for each asset the user owns
        for (uint256 i = 0; i < debtToRepay.length; i++) {
            // repay the debt
            aavePool.repay({
                asset: debtToRepay[i].asset,
                amount: debtToRepay[i].amount,
                interestRateMode: debtToRepay[i].rateMode,
                onBehalfOf: user
            });
        }

        emit DebtRepayed({user: user, debts: debtToRepay});

        _vampNoBorrow(user, assetsToMigrate);

        return true;
    }
}
