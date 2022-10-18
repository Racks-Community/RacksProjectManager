//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IRacksProjectManager.sol";
import "./interfaces/IMRC.sol";
import "./Project.sol";
import "./Contributor.sol";
import "./Err.sol";
import "./library/StructuredLinkedList.sol";

//              ▟██████████   █████    ▟███████████   █████████████
//            ▟████████████   █████  ▟█████████████   █████████████   ███████████▛
//           ▐█████████████   █████▟███████▛  █████   █████████████   ██████████▛
//            ▜██▛    █████   ███████████▛    █████       ▟██████▛    █████████▛
//              ▀     █████   █████████▛      █████     ▟██████▛
//                    █████   ███████▛      ▟█████▛   ▟██████▛
//   ▟█████████████   ██████              ▟█████▛   ▟██████▛   ▟███████████████▙
//  ▟██████████████   ▜██████▙          ▟█████▛   ▟██████▛   ▟██████████████████▙
// ▟███████████████     ▜██████▙      ▟█████▛   ▟██████▛   ▟█████████████████████▙
//                        ▜██████▙            ▟██████▛          ┌────────┐
//                          ▜██████▙        ▟██████▛            │  LABS  │
//                                                              └────────┘

contract RacksProjectManager is IRacksProjectManager, Ownable, AccessControl {
    /// @notice tokens
    IMRC private immutable mrc;
    IERC20 private erc20;

    /// @notice State variables
    bytes32 private constant ADMIN_ROLE = 0x00;
    address[] private contributors;
    bool private paused;
    uint256 progressiveId;

    using StructuredLinkedList for StructuredLinkedList.List;
    StructuredLinkedList.List private projectsList;
    mapping(uint256 => Project) private projectStore;
    Project[] private projectsDeleted;

    mapping(address => bool) private walletIsContributor;
    mapping(address => bool) private accountIsBanned;
    mapping(address => uint256) private projectId;
    mapping(address => Contributor) private contributorsData;

    /// @notice Check that user is Admin
    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert adminErr();
        _;
    }

    /// @notice Check that user is Holder or Admin
    modifier onlyHolder() {
        if (mrc.balanceOf(msg.sender) < 1 && !hasRole(ADMIN_ROLE, msg.sender)) revert holderErr();
        _;
    }

    /// @notice Check that the smart contract is paused
    modifier isNotPaused() {
        if (paused) revert pausedErr();
        _;
    }

    ///////////////////
    //  Constructor  //
    ///////////////////
    constructor(IMRC _mrc, IERC20 _erc20) {
        erc20 = _erc20;
        mrc = _mrc;
        _setupRole(ADMIN_ROLE, msg.sender);
    }

    ///////////////////////
    //  Logic Functions  //
    ///////////////////////

    /**
     * @notice Create Project
     * @dev Only callable by Admins
     */
    function createProject(
        string memory _name,
        uint256 _colateralCost,
        uint256 _reputationLevel,
        uint256 _maxContributorsNumber
    ) external onlyAdmin isNotPaused {
        if (
            _colateralCost <= 0 ||
            _reputationLevel <= 0 ||
            _maxContributorsNumber <= 0 ||
            bytes(_name).length <= 0
        ) revert projectInvalidParameterErr();

        Project newProject = new Project(
            this,
            _name,
            _colateralCost,
            _reputationLevel,
            _maxContributorsNumber
        );

        progressiveId++;
        projectStore[progressiveId] = newProject;
        projectId[address(newProject)] = progressiveId;
        projectsList.pushFront(progressiveId);

        _setupRole(ADMIN_ROLE, address(newProject));
        emit newProjectCreated(_name, address(newProject));
    }

    /**
     * @notice Add Contributor
     * @dev Only callable by Holders who are not already Contributors
     */
    function registerContributor() external onlyHolder isNotPaused {
        if (walletIsContributor[msg.sender]) revert contributorAlreadyExistsErr();

        contributors.push(msg.sender);
        walletIsContributor[msg.sender] = true;
        contributorsData[msg.sender] = Contributor(msg.sender, 1, 0, false);
        emit newContributorRegistered(msg.sender);
    }

    /**
     * @notice Used to withdraw All funds
     * @dev Only owner is able to call this function
     */
    function withdrawAllFunds(address _wallet) external onlyOwner isNotPaused {
        if (erc20.balanceOf(address(this)) <= 0) revert noFundsWithdrawErr();
        if (!erc20.transfer(_wallet, erc20.balanceOf(address(this)))) revert erc20TransferFailed();
    }

    ////////////////////////
    //  Helper Functions  //
    ////////////////////////

    /**
     * @notice Set new Admin
     * @dev Only callable by the Admin
     */
    function addAdmin(address _newAdmin) external onlyOwner {
        grantRole(ADMIN_ROLE, _newAdmin);
    }

    /**
     * @notice Remove an account from the user role
     * @dev Only callable by the Admin
     */
    function removeAdmin(address _account) external virtual onlyOwner {
        revokeRole(ADMIN_ROLE, _account);
    }

    ///////////////////////
    //  Setter Functions //
    ///////////////////////

    /**
     * @notice Set new ERC20 Token
     * @dev Only callable by the Admin
     */
    function setERC20Address(address _erc20) external onlyAdmin {
        erc20 = IERC20(_erc20);
    }

    /**
     * @notice Set a ban state for a Contributor
     * @dev Only callable by Admins.
     */
    function setContributorStateToBanList(address _account, bool _state) external onlyAdmin {
        accountIsBanned[_account] = _state;

        if (_state == true) {
            (bool existNext, uint256 i) = projectsList.getNextNode(0);

            while (i != 0 && existNext) {
                Project project = projectStore[i];

                if (project.isActive() && project.isContributorInProject(_account)) {
                    project.removeContributor(_account, false);
                }

                (existNext, i) = projectsList.getNextNode(i);
            }
        }
    }

    /// @inheritdoc IRacksProjectManager
    function setAccountToContributorData(address _account, Contributor memory _newData)
        public
        override
        onlyAdmin
    {
        contributorsData[_account] = _newData;
    }

    /// Increase Contributor's Reputation Level
    function increaseContributorLv(address _account, uint256 levels) public onlyAdmin {
        if (levels <= 0) revert invalidParameterErr();
        Contributor memory contributor = contributorsData[_account];
        contributor.reputationLevel += levels;
        contributor.reputationPoints = 0;
        contributorsData[_account] = contributor;
    }

    function setIsPaused(bool _newPausedValue) public onlyAdmin {
        paused = _newPausedValue;
    }

    ////////////////////////
    //  Getter Functions //
    //////////////////////

    /// @inheritdoc IRacksProjectManager
    function isAdmin(address _account) public view override returns (bool) {
        return hasRole(ADMIN_ROLE, _account);
    }

    /// @notice Returns MRC address
    function getMRCInterface() external view returns (IMRC) {
        return mrc;
    }

    /// @inheritdoc IRacksProjectManager
    function getERC20Interface() public view override returns (IERC20) {
        return erc20;
    }

    /// @inheritdoc IRacksProjectManager
    function getRacksPMOwner() public view override returns (address) {
        return owner();
    }

    /// @inheritdoc IRacksProjectManager
    function isContributorBanned(address _account) external view override returns (bool) {
        return accountIsBanned[_account];
    }

    /**
     * @notice Get projects depending on Level
     * @dev Only callable by Holders
     */
    function getProjects() public view onlyHolder returns (Project[] memory) {
        if (hasRole(ADMIN_ROLE, msg.sender)) return getAllProjects();
        Project[] memory filteredProjects = new Project[](projectsList.sizeOf());

        unchecked {
            uint256 callerReputationLv = walletIsContributor[msg.sender]
                ? contributorsData[msg.sender].reputationLevel
                : 1;
            uint256 j = 0;
            (bool existNext, uint256 i) = projectsList.getNextNode(0);

            while (i != 0 && existNext) {
                if (projectStore[i].getReputationLevel() <= callerReputationLv) {
                    filteredProjects[j] = projectStore[i];
                    j++;
                }
                (existNext, i) = projectsList.getNextNode(i);
            }
        }

        return filteredProjects;
    }

    function getAllProjects() public view returns (Project[] memory) {
        Project[] memory allProjects = new Project[](projectsList.sizeOf());

        uint256 j = 0;
        (bool existNext, uint256 i) = projectsList.getNextNode(0);

        while (i != 0 && existNext) {
            allProjects[j] = projectStore[i];
            j++;
            (existNext, i) = projectsList.getNextNode(i);
        }

        return allProjects;
    }

    function getProjectsDeleted() public view returns (Project[] memory) {
        return projectsDeleted;
    }

    /// @notice Get Contributor by index
    function getContributor(uint256 _index) public view returns (Contributor memory) {
        return contributorsData[contributors[_index]];
    }

    /// @inheritdoc IRacksProjectManager
    function isWalletContributor(address _account) public view override returns (bool) {
        return walletIsContributor[_account];
    }

    /// @inheritdoc IRacksProjectManager
    function getContributorData(address _account)
        public
        view
        override
        returns (Contributor memory)
    {
        return contributorsData[_account];
    }

    /**
     * @notice Get total number of projects
     * @dev Only callable by Holders
     */
    function getNumberOfProjects() external view onlyHolder returns (uint256) {
        return projectsList.sizeOf();
    }

    /**
     * @notice Get total number of contributors
     * @dev Only callable by Holders
     */
    function getNumberOfContributors() external view onlyHolder returns (uint256) {
        return contributors.length;
    }

    /// @inheritdoc IRacksProjectManager
    function isPaused() external view override returns (bool) {
        return paused;
    }

    /// @inheritdoc IRacksProjectManager
    function deleteProject() external override {
        uint256 id = projectId[msg.sender];

        require(id != 0);

        projectId[msg.sender] = 0;
        projectsList.remove(id);
        projectsDeleted.push(Project(payable(msg.sender)));
    }
}
