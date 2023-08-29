// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PRBProxy} from "prb-proxy/PRBProxy.sol";

import {Permission} from "../../utils/Permission.sol";
import {toInt256, WAD} from "../../utils/Math.sol";

import {CDPVault} from "../../CDPVault.sol";
import {CDPVault_TypeA} from "../../CDPVault_TypeA.sol";

import {IntegrationTestBase} from "./IntegrationTestBase.sol";

import {BaseAction} from "../../proxy/BaseAction.sol";
import {PermitParams} from "../../proxy/TransferAction.sol";
import {SwapAction, SwapParams, SwapType, SwapProtocol} from "../../proxy/SwapAction.sol";
import {newPositionActionV3, CollateralParams, CreditParams} from "../../proxy/newPositionAction.sol";
import {newPositionAction20} from "../../proxy/newPositionAction20.sol";

import {wmul} from "../../utils/Math.sol";

import "forge-std/console.sol";

//420000000000000000000
//210000000000000000000

//forge test --match src/test/integration/newPositionAction20.t.sol
//forge test --match-test newPositionAction20
//forge test --match-path src/test/integration/newPositionAction20.t.sol --rpc-url https://rpc.tenderly.co/fork/a0a9ebe2-8875-44a8-af17-265596d208ef

contract newPositionAction20Test is IntegrationTestBase {
    using SafeERC20 for ERC20;

    address user;
    uint256 constant userPk = 0x12341234;

    // cdp vaults
    CDPVault_TypeA daiVault;
    CDPVault_TypeA usdcVault;
    CDPVault_TypeA usdtVault;

    // actions
    newPositionAction20 positionAction;

    // common variables as state variables to help with stack too deep
    PermitParams emptyPermitParams;
    SwapParams emptySwap;
    bytes32[] stablePoolIdArray;

    function setUp() public override {
        super.setUp();

        // configure permissions and system settings
        setGlobalDebtCeiling(15_000_000 ether);

        // deploy vaults
        usdcVault = createCDPVault_TypeA(
            USDC, // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether, // liquidation discount
            1.05 ether, // target health factor
            WAD, // price tick to rebate factor conversion bias
            1.1 ether, // max rebate
            BASE_RATE_1_005, // base rate
            0, // protocol fee
            0 // global liquidation ratio
        );

        daiVault = createCDPVault_TypeA(
            DAI, // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether, // liquidation discount
            1.05 ether, // target health factor
            WAD, // price tick to rebate factor conversion bias
            1.1 ether, // max rebate
            BASE_RATE_1_005, // base rate
            0, // protocol fee
            0 // global liquidation ratio
        );

        usdtVault = createCDPVault_TypeA(
            USDT, // token
            5_000_000 ether, // debt ceiling
            0, // debt floor
            1.25 ether, // liquidation ratio
            1.0 ether, // liquidation penalty
            1.05 ether, // liquidation discount
            1.05 ether, // target health factor
            WAD, // price tick to rebate factor conversion bias
            1.1 ether, // max rebate
            BASE_RATE_1_005, // base rate
            0, // protocol fee
            0 // global liquidation ratio
        );

        daiVault.addLimitPriceTick(1 ether, 0);

        // configure oracle spot prices
        oracle.updateSpot(address(DAI), 1 ether);
        oracle.updateSpot(address(USDC), 1 ether);
        oracle.updateSpot(address(USDT), 1 ether);

        // configure vaults
        cdm.setParameter(address(daiVault), "debtCeiling", 5_000_000 ether);
        cdm.setParameter(address(usdcVault), "debtCeiling", 5_000_000 ether);
        cdm.setParameter(address(usdtVault), "debtCeiling", 5_000_000 ether);

        // setup user
        user = vm.addr(0x12341234);
        
        // deploy position action
        positionAction = new newPositionAction20(address(flashlender), address(swapAction));

        // set up variables to avoid stack too deep
        stablePoolIdArray.push(stablePoolId);

        // give minter credit to cover interest
        createCredit(address(minter), 5_000_000 ether);

        vm.label(user, "user");
        //vm.label(address(userProxy), "userProxy");
        vm.label(address(daiVault), "daiVault");
        vm.label(address(usdcVault), "usdcVault");
        vm.label(address(usdtVault), "usdtVault");
        vm.label(address(positionAction), "positionAction");
    }

    /*Working but not relevant
    function test_deposit() public {
        uint256 depositAmount = 10_000 ether;

        deal(address(DAI), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(DAI),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.prank(user);
        DAI.approve(address(positionAction), depositAmount);

        vm.prank(user);
        positionAction.executeDeposit(address(daiVault), address(DAI), depositAmount);

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(user));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);

        
        //Check to see if the CDM has a representation of the User account
        (int256 balance, uint256 debtCeiling) = cdm.accounts(address(user));
        //Compare the cdm account balance to the user's posted collateral...
        //This test is probably flawed because 
        assertEq(balance, int256(collateral) );
        
    }
    */

    
    //Working - no undelegation
    function test_delegate_with_stablecoin() public {
        uint256 depositAmount = 10_000 ether;
        uint256 borrowAmount = 5_000 ether;
        uint256 creditAmount = 2_500 ether;

        deal(address(DAI), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(DAI),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap
        });

        vm.startPrank(user);
        DAI.approve(address(positionAction), depositAmount);
        positionAction.executeDeposit(address(daiVault), address(DAI), depositAmount);

        daiVault.modifyPermission(address(positionAction), true);
        cdm.setPermissionAgent(address(positionAction), true);
        positionAction.executeBorrow(address(daiVault), borrowAmount);
        cdm.setPermissionAgent(address(positionAction), false);

        //User approves the positionAction with the stablecoin
        stablecoin.approve(address(positionAction), creditAmount);
        positionAction.beginDelegateViaStablecoin(user, address(usdcVault), creditAmount);

        cdm.modifyPermission(address(usdcVault), true);
        usdcVault.delegateCredit(creditAmount);
        cdm.modifyPermission(address(usdcVault), false);

        vm.stopPrank();

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(user));
        //Does the positionAction contract somehow end up with the fuckin shares??
        //Yep...the positionAction contract has ended up with the shares....
        //uint256 shares = daiVault.shares(address(positionAction));
        uint256 shares = usdcVault.shares(user);

        assertEq(collateral, depositAmount); //collateral is as deposited
        assertEq(normalDebt, borrowAmount); //debt in the vault is as borrowed
        assertEq(shares, creditAmount); //shares in the delegated vault is as delegated
    }


    function test_delegate_and_undelegateIntoStablecoin() public {
        uint256 depositAmount = 10_000 ether;
        uint256 borrowAmount = 5_000 ether;
        uint256 creditAmount = 2_500 ether;

        deal(address(DAI), user, depositAmount);

        vm.startPrank(user);
        DAI.approve(address(positionAction), depositAmount);
        positionAction.executeDeposit(address(daiVault), address(DAI), depositAmount);

        daiVault.modifyPermission(address(positionAction), true);
        cdm.setPermissionAgent(address(positionAction), true);
        positionAction.executeBorrow(address(daiVault), borrowAmount);
        cdm.setPermissionAgent(address(positionAction), false);
        daiVault.modifyPermission(address(positionAction), false);


        //User approves the positionAction with the stablecoin
        stablecoin.approve(address(positionAction), creditAmount);
        positionAction.beginDelegateViaStablecoin(user, address(usdcVault), creditAmount);

        cdm.modifyPermission(address(usdcVault), true);
        usdcVault.delegateCredit(creditAmount);
        cdm.modifyPermission(address(usdcVault), false);
        //Ensure that the mapping of epochOfDelegation is correct (the current epoch)
        assertEq(usdcVault.epochOfDelegation(user), usdcVault.getCurrentEpoch());

        //Begin to undelegate
        //Get the user's shares.
         uint256 shares = usdcVault.shares(user);
        //Create the prevQueuedEpochs array...taking the epoch that the user first delegated into the vault.
        uint256[] memory prevQueuedEpochs = new uint256[](1);
         prevQueuedEpochs[0] = usdcVault.epochOfDelegation(user);
        //Call this function directly on the vault.
        ( ,uint256 epoch, uint256 claimableAtEpoch, ) = usdcVault.undelegateCredit(shares, prevQueuedEpochs);
        
        //Now we are ready to move along and warp to the timestamp where credit is claimable
        vm.warp(block.timestamp + (usdcVault.EPOCH_FIX_DELAY() * usdcVault.EPOCH_DURATION()));
        //Ensure that the epoch is the correct one.
        assertEq(usdcVault.getCurrentEpoch(), claimableAtEpoch);

        //User claims the undelegatedCredit 
            //Takes the epoch the credit was initially undelegatedAt
        uint256 undelegatedCredit = usdcVault.claimUndelegatedCredit(epoch); 

        cdm.setPermissionAgent(address(positionAction), true);
        positionAction.turnCreditIntoStable(undelegatedCredit);
        cdm.setPermissionAgent(address(positionAction), false);

        vm.stopPrank();

        //user has deposited 10,000 //normal deposit logic
        //user has borrowed 5,000         | +5,000 STBl |  0 credit //normal borrow logic
        //user delegated 2,500            | -2,500 STBL | +2,500 credit -> delegated away
        //user undelegate 2,500           |     N/A     | Queued: +2,500 
        //user claimUndelegatedCredit     |     N/A     | +2,500 credit
        //user turns creditIntoStablecoin | +2,500 STBL | -2,500 credit
        //user repays debt                |-5,000+ STBL | N/A
        //normal withdrawal logic

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(user)); //Deposit vault information
        shares = usdcVault.shares(user); //Delegated vault share information
        (int256 cdmBalance, ) = cdm.accounts(user); //Get cdmBalance
        uint256 stablecoinBal = stablecoin.balanceOf(user); //Get the user's stablecoin balance
      
        assertEq(collateral, depositAmount); //collateral is as deposited
        assertEq(cdmBalance, 0); // ensure the cdm balanc of the user is now zero...
        assertEq(stablecoinBal, borrowAmount); //user now has their original borrow amount of stableCoin
        //assertEq(shares, 0); //shares in the delegated vault is 0
    }

//Everything working except I need to do the math to find out just exactly how much stablecoin to approve for repayment
    function test_delegate_and_undelegateIntoStablecoin_thenRepay() public {
        uint256 depositAmount = 10_000 ether;
        uint256 borrowAmount = 5_000 ether;
        uint256 creditAmount = 2_500 ether;

        deal(address(DAI), user, depositAmount);

        vm.startPrank(user);
        DAI.approve(address(positionAction), depositAmount);
        positionAction.executeDeposit(address(daiVault), address(DAI), depositAmount);

        daiVault.modifyPermission(address(positionAction), true);
        cdm.setPermissionAgent(address(positionAction), true);
        positionAction.executeBorrow(address(daiVault), borrowAmount);
        cdm.setPermissionAgent(address(positionAction), false);
        daiVault.modifyPermission(address(positionAction), false);


        //User approves the positionAction with the stablecoin
        stablecoin.approve(address(positionAction), creditAmount);
        positionAction.beginDelegateViaStablecoin(user, address(usdcVault), creditAmount);

        cdm.modifyPermission(address(usdcVault), true);
        usdcVault.delegateCredit(creditAmount);
        cdm.modifyPermission(address(usdcVault), false);
        //Ensure that the mapping of epochOfDelegation is correct (the current epoch)
        assertEq(usdcVault.epochOfDelegation(user), usdcVault.getCurrentEpoch());

        //Begin to undelegate
        //Get the user's shares.
         uint256 shares = usdcVault.shares(user);
        //Create the prevQueuedEpochs array...taking the epoch that the user first delegated into the vault.
        uint256[] memory prevQueuedEpochs = new uint256[](1);
         prevQueuedEpochs[0] = usdcVault.epochOfDelegation(user);
        //Call this function directly on the vault.
        ( ,uint256 epoch, uint256 claimableAtEpoch, ) = usdcVault.undelegateCredit(shares, prevQueuedEpochs);
        
        //Now we are ready to move along and warp to the timestamp where credit is claimable
        vm.warp(block.timestamp + (usdcVault.EPOCH_FIX_DELAY() * usdcVault.EPOCH_DURATION()));
        //Ensure that the epoch is the correct one.
        assertEq(usdcVault.getCurrentEpoch(), claimableAtEpoch);

        //User claims the undelegatedCredit 
            //Takes the epoch the credit was initially undelegatedAt
        uint256 undelegatedCredit = usdcVault.claimUndelegatedCredit(epoch); 

        cdm.setPermissionAgent(address(positionAction), true);
        positionAction.turnCreditIntoStable(undelegatedCredit);
        cdm.setPermissionAgent(address(positionAction), false);
        
        
        uint256 currentBalanceOfUser = stablecoin.balanceOf(user);
        uint256 interestPayment = 1000 ether;

        //Need to do math to determine how much stablecoin is needed to repay a loan
        //Give the user some more stablecoins - that they would've bought to pay off their loan
        deal(address(stablecoin), user, currentBalanceOfUser + interestPayment);
        stablecoin.approve(address(positionAction), currentBalanceOfUser + interestPayment); //approve a much higher amount than is required
        //need to do the math to get the exact amount to approve for a repayment...

        (,uint256 normalDebtCurrent) = daiVault.positions(user); //get the normalDebtAmount to repay
        daiVault.modifyPermission(address(positionAction), true);
        cdm.setPermissionAgent(address(positionAction), true);
        positionAction.executeRepay(address(daiVault), normalDebtCurrent);
        cdm.setPermissionAgent(address(positionAction), false);
        daiVault.modifyPermission(address(positionAction), false);

        vm.stopPrank();

        //user has deposited 10,000 //normal deposit logic
        //user has borrowed 5,000         | +5,000 STBl |  0 credit //normal borrow logic
        //user delegated 2,500            | -2,500 STBL | +2,500 credit -> delegated away
        //user undelegate 2,500           |     N/A     | Queued: +2,500 
        //user claimUndelegatedCredit     |     N/A     | +2,500 credit
        //user turns creditIntoStablecoin | +2,500 STBL | -2,500 credit
        //user repays debt                |-5,000+ STBL | 0 credit
        //normal withdrawal logic

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(user)); //Deposit vault information
        shares = usdcVault.shares(user); //Delegated vault share information
        (int256 cdmBalance, ) = cdm.accounts(user); //Get cdmBalance
        //uint256 stablecoinBal = stablecoin.balanceOf(user); //Get the user's stablecoin balance
      
        assertEq(collateral, depositAmount); //collateral is as deposited
        assertEq(normalDebt, 0); //ensure there is no more debt in the position
        assertEq(cdmBalance, 0); // ensure the cdm balanc of the user is now zero...
    }

    //Just putting this function here so I don't have to go looking for this math.
    function _virtualDebtHere(CDPVault_TypeA vault, address position) internal view returns (uint256) {
        (, uint256 normalDebt) = vault.positions(position);
        (uint64 rateAccumulator, uint256 accruedRebate, ) = vault.virtualIRS(position);
        return wmul(rateAccumulator, normalDebt) - accruedRebate;
    }

}
