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
import {newPositionAction, CollateralParams, CreditParams} from "../../proxy/newPositionAction.sol";
import {newPositionAction20V2} from "../../proxy/newPositionAction20.sol";

import "forge-std/console.sol";

//420000000000000000000
//210000000000000000000

//forge test --match src/test/integration/newPositionAction20.t.sol
//forge test --match-test newPositionAction20
//forge test --match-path src/test/integration/newPositionAction20.t.sol --rpc-url https://rpc.tenderly.co/fork/a0a9ebe2-8875-44a8-af17-265596d208ef

contract newPositionAction20 is IntegrationTestBase {
    using SafeERC20 for ERC20;

    address user;
    uint256 constant userPk = 0x12341234;

    // cdp vaults
    CDPVault_TypeA daiVault;
    CDPVault_TypeA usdcVault;
    CDPVault_TypeA usdtVault;

    // actions
    newPositionAction20V2 positionAction;

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
        positionAction = new newPositionAction20V2(address(flashlender), address(swapAction));

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

        /*
        //Check to see if the CDM has a representation of the User account
        (int256 balance, uint256 debtCeiling) = cdm.accounts(address(user));
        //Compare the cdm account balance to the user's posted collateral...
        //This test is probably flawed because 
        assertEq(balance, int256(collateral) );
        */
    }

    // DELEGATION TESTS


    //Shares are incorrectly being sent to the positionAction contract...
    //Because it is the collateralizer and creditor in the modifyCollateral calls?
    function test_depositAndDelegate() public {
        uint256 depositAmount = 10_000*1 ether;
        uint256 creditAmount = 5_000*1 ether;

        deal(address(DAI), user, depositAmount);

        CollateralParams memory collateralParams = CollateralParams({
            targetToken: address(DAI),
            amount: depositAmount,
            collateralizer: address(user),
            auxSwap: emptySwap // no entry swap
        });

        vm.startPrank(user);
        DAI.approve(address(positionAction), depositAmount);

        cdm.setPermissionAgent(address(positionAction), true);
        
        daiVault.modifyPermission(address(positionAction), true);
        
        positionAction._depositAndDelegate(address(user), address(daiVault), address(daiVault), creditAmount, collateralParams, emptyPermitParams);
        vm.stopPrank();

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(user));
        //Does the positionAction contract somehow end up with the fuckin shares??
        //Yep...the positionAction contract has ended up with the shares....
        //uint256 shares = daiVault.shares(address(positionAction));
        uint256 shares = daiVault.shares(address(positionAction));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, creditAmount);
        assertEq(shares, creditAmount);
    }


//both of these tests fail in the same way...with the same inputs.
//This failure is the same one that I get when interacting with the deployed system
    //on tenderly. 
//The position does not have the required balance with the CDM to transfer its collateral to another vault
//I am unsure if the position is even being represented with the CDM??
//When doing the 'test_deposit', and I have made some assertions regarding the user's position on the CDM
    //And these assertions failed, there was no updating of the CDM when creating a vault position.

    //This is the sequence of calls that I want to occur...first a deposit..then delegate
    //Depositing depositAmount
    //Then modifyCollateral to set up the creditAmount as debt...
    //Then try to delegate that creditAmount...using the call on the positionAction 
    function test_deposit_then_delegate_Type1() public
    {
        uint256 depositAmount = 10_000 ether;
        uint256 creditAmount = 5_000*1 ether;

        deal(address(DAI), user, depositAmount);

        vm.startPrank(user);
        DAI.approve(address(positionAction), depositAmount);

        cdm.setPermissionAgent(address(positionAction), true);
        
        daiVault.modifyPermission(address(positionAction), true);

        //Deposits into vault
        positionAction.executeDeposit(address(daiVault), address(DAI), depositAmount);

        uint256 collateralCurrent;
        uint256 normalDebtCurrent;
        (collateralCurrent, normalDebtCurrent) = daiVault.positions(address(user));
        console.log("%s: %s:%s", "Post Deposit collateral/debt:", collateralCurrent , normalDebtCurrent);

        daiVault.modifyCollateralAndDebt( address(user), 
                                address(positionAction), 
                                address(positionAction),
                                0,
                                int256(creditAmount)                                
                                );
        
        (collateralCurrent, normalDebtCurrent) = daiVault.positions(address(user));
        console.log("%s: %s:%s", "Modified collateral/debt:", collateralCurrent, normalDebtCurrent);
        
        //address owner,
        //address collateralizer,
        //address creditor,
        //int256 deltaCollateral,
        //int256 deltaNormalDebt

        cdm.modifyPermission(address(daiVault), true);
        positionAction.executeDelegateTry(address(daiVault), creditAmount);
        cdm.modifyPermission(address(daiVault), false);

        vm.stopPrank();

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(user));
       // uint256 shares = daiVault.shares(address(user));

        assertEq(collateral, depositAmount);
        assertEq(normalDebt, 0);
       // assertEq(shares, creditAmount); 
    }

    //This is kind of calls that I want to occur...first a deposit..then delegate
    //Depositing depositAmount
    //Then modifyCollateral to set up the creditAmount as debt...
    //Then try to delegate that creditAmount...using the call on the vault itself...
    function test_deposit_then_delegate_Type2() public
    {
        uint256 depositAmount = 10_000 ether;
        uint256 creditAmount = 5_000*1 ether;

        deal(address(DAI), user, depositAmount);

        vm.startPrank(user);
        DAI.approve(address(positionAction), depositAmount);

        cdm.setPermissionAgent(address(positionAction), true);
        
        daiVault.modifyPermission(address(positionAction), true);

        //Deposits into vault
        positionAction.executeDeposit(address(daiVault), address(DAI), depositAmount);

        uint256 collateralCurrent;
        uint256 normalDebtCurrent;
        (collateralCurrent, normalDebtCurrent) = daiVault.positions(address(user));
        console.log("%s: %s:%s", "Post Deposit collateral/debt:", collateralCurrent , normalDebtCurrent);

        daiVault.modifyCollateralAndDebt( address(user), 
                                address(positionAction), 
                                address(positionAction),
                                0,
                                int256(creditAmount)                                
                                );
        
        (collateralCurrent, normalDebtCurrent) = daiVault.positions(address(user));
        console.log("%s: %s:%s", "Modified collateral/debt:", collateralCurrent, normalDebtCurrent);
        
        //address owner,
        //address collateralizer,
        //address creditor,
        //int256 deltaCollateral,
        //int256 deltaNormalDebt

        cdm.modifyPermission(address(daiVault), true);
        //Call the delegate credit attempt directly on the daiVault...
        daiVault.delegateCreditTry(address(user), creditAmount);
        cdm.modifyPermission(address(daiVault), false);

        vm.stopPrank();

        (uint256 collateral, uint256 normalDebt) = daiVault.positions(address(user));
       // uint256 shares = daiVault.shares(address(user));

        assertEq(collateral, depositAmount);
        //assertEq(normalDebt, 0);
       // assertEq(shares, creditAmount); 
    }
}
